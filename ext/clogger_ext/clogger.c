#define _BSD_SOURCE
#include <ruby.h>
#include <assert.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/time.h>
#include <time.h>
#include <errno.h>
#ifdef HAVE_FCNTL_H
#  include <fcntl.h>
#endif
#include "ruby_1_9_compat.h"

/* in case _BSD_SOURCE doesn't give us this macro */
#ifndef timersub
#  define timersub(a, b, result) \
do { \
	(result)->tv_sec = (a)->tv_sec - (b)->tv_sec; \
	(result)->tv_usec = (a)->tv_usec - (b)->tv_usec; \
	if ((result)->tv_usec < 0) { \
		--(result)->tv_sec; \
		(result)->tv_usec += 1000000; \
	} \
} while (0)
#endif

/* give GCC hints for better branch prediction
 * (we layout branches so that ASCII characters are handled faster) */
#if defined(__GNUC__) && (__GNUC__ >= 3)
#  define likely(x)		__builtin_expect (!!(x), 1)
#  define unlikely(x)		__builtin_expect (!!(x), 0)
#else
#  define unlikely(x)		(x)
#  define likely(x)		(x)
#endif

enum clogger_opcode {
	CL_OP_LITERAL = 0,
	CL_OP_REQUEST,
	CL_OP_RESPONSE,
	CL_OP_SPECIAL,
	CL_OP_EVAL,
	CL_OP_TIME_LOCAL,
	CL_OP_TIME_UTC,
	CL_OP_REQUEST_TIME,
	CL_OP_TIME,
	CL_OP_COOKIE
};

enum clogger_special {
	CL_SP_body_bytes_sent = 0,
	CL_SP_status,
	CL_SP_request,
	CL_SP_request_length,
	CL_SP_response_length,
	CL_SP_ip,
	CL_SP_pid,
	CL_SP_request_uri
};

struct clogger {
	VALUE app;

	VALUE fmt_ops;
	VALUE logger;
	VALUE log_buf;

	VALUE env;
	VALUE cookies;
	VALUE response;

	off_t body_bytes_sent;
	struct timeval tv_start;

	int fd;
	int wrap_body;
	int need_resp;
	int reentrant; /* tri-state, -1:auto, 1/0 true/false */
};

static ID ltlt_id;
static ID call_id;
static ID each_id;
static ID close_id;
static ID to_i_id;
static ID to_s_id;
static ID size_id;
static VALUE cClogger;
static VALUE mFormat;

/* common hash lookup keys */
static VALUE g_HTTP_X_FORWARDED_FOR;
static VALUE g_REMOTE_ADDR;
static VALUE g_REQUEST_METHOD;
static VALUE g_PATH_INFO;
static VALUE g_REQUEST_URI;
static VALUE g_QUERY_STRING;
static VALUE g_HTTP_VERSION;
static VALUE g_rack_errors;
static VALUE g_rack_input;
static VALUE g_rack_multithread;
static VALUE g_dash;
static VALUE g_empty;
static VALUE g_space;
static VALUE g_question_mark;
static VALUE g_rack_request_cookie_hash;
static VALUE g_bad_app_response;

#define LOG_BUF_INIT_SIZE 128

static void init_buffers(struct clogger *c)
{
	c->log_buf = rb_str_buf_new(LOG_BUF_INIT_SIZE);
}

static inline int need_escape(unsigned c)
{
	assert(c <= 0xff);
	return !!(c == '\'' || c == '"' || (c >= 0 && c <= 0x1f));
}

/* we are encoding-agnostic, clients can send us all sorts of junk */
static VALUE byte_xs(VALUE from)
{
	static const char esc[] = "0123456789ABCDEF";
	unsigned char *new_ptr;
	unsigned char *ptr = (unsigned char *)RSTRING_PTR(from);
	long len = RSTRING_LEN(from);
	long new_len = len;
	VALUE rv;

	for (; --len >= 0; ptr++) {
		unsigned c = *ptr;

		if (unlikely(need_escape(c)))
			new_len += 3; /* { '\', 'x', 'X', 'X' } */
	}

	len = RSTRING_LEN(from);
	if (new_len == len)
		return from;

	rv = rb_str_new(0, new_len);
	new_ptr = (unsigned char *)RSTRING_PTR(rv);
	ptr = (unsigned char *)RSTRING_PTR(from);
	for (; --len >= 0; ptr++) {
		unsigned c = *ptr;

		if (unlikely(need_escape(c))) {
			*new_ptr++ = '\\';
			*new_ptr++ = 'x';
			*new_ptr++ = esc[c >> 4];
			*new_ptr++ = esc[c & 0xf];
		} else {
			*new_ptr++ = c;
		}
	}
	assert(RSTRING_PTR(rv)[RSTRING_LEN(rv)] == '\0');

	return rv;
}

/* strcasecmp isn't locale independent, so we roll our own */
static int str_case_eq(VALUE a, VALUE b)
{
	long alen = RSTRING_LEN(a);
	long blen = RSTRING_LEN(b);

	if (alen == blen) {
		const char *aptr = RSTRING_PTR(a);
		const char *bptr = RSTRING_PTR(b);

		for (; alen--; ++aptr, ++bptr) {
			if ((*bptr == *aptr)
			    || (*aptr >= 'A' && *aptr <= 'Z' &&
			        (*aptr | 0x20) == *bptr))
				continue;
			return 0;
		}
		return 1;
	}
	return 0;
}

struct response_ops { long nr; VALUE ops; };

/* this can be worse than O(M*N) :<... but C loops are fast ... */
static VALUE swap_sent_headers_unsafe(VALUE kv, VALUE memo)
{
	struct response_ops *tmp = (struct response_ops *)memo;
	VALUE key = rb_obj_as_string(RARRAY_PTR(kv)[0]);
	long i = RARRAY_LEN(tmp->ops);
	VALUE *ary = RARRAY_PTR(tmp->ops);
	VALUE value;

	for (; --i >= 0; ary++) {
		VALUE *op = RARRAY_PTR(*ary);
		enum clogger_opcode opcode = NUM2INT(op[0]);

		if (opcode != CL_OP_RESPONSE)
			continue;
		assert(RARRAY_LEN(*ary) == 2);
		if (!str_case_eq(key, op[1]))
			continue;

		value = RARRAY_PTR(kv)[1];
		op[0] = INT2NUM(CL_OP_LITERAL);
		op[1] = byte_xs(rb_obj_as_string(value));

		if (!--tmp->nr)
			rb_iter_break();
		return Qnil;
	}
	return Qnil;
}

static VALUE swap_sent_headers(VALUE kv, VALUE memo)
{
	if (TYPE(kv) != T_ARRAY)
		rb_raise(rb_eTypeError, "headers not returning pairs");
	if (RARRAY_LEN(kv) < 2)
		rb_raise(rb_eTypeError, "headers not returning pairs");
	return swap_sent_headers_unsafe(kv, memo);
}

static VALUE sent_headers_ops(struct clogger *c)
{
	struct response_ops tmp;
	long i, len;
	VALUE *ary;

	if (!c->need_resp)
		return c->fmt_ops;

	tmp.nr = 0;
	tmp.ops = rb_ary_dup(c->fmt_ops);
	len = RARRAY_LEN(tmp.ops);
	ary = RARRAY_PTR(tmp.ops);

	for (i = 0; i < len; ++i) {
		VALUE *op = RARRAY_PTR(ary[i]);

		if (NUM2INT(op[0]) == CL_OP_RESPONSE) {
			assert(RARRAY_LEN(ary[i]) == 2);
			ary[i] = rb_ary_dup(ary[i]);
			++tmp.nr;
		}
	}

	rb_iterate(rb_each, RARRAY_PTR(c->response)[1],
	           swap_sent_headers, (VALUE)&tmp);

	return tmp.ops;
}

static void clogger_mark(void *ptr)
{
	struct clogger *c = ptr;

	rb_gc_mark(c->app);
	rb_gc_mark(c->fmt_ops);
	rb_gc_mark(c->logger);
	rb_gc_mark(c->log_buf);
	rb_gc_mark(c->env);
	rb_gc_mark(c->cookies);
	rb_gc_mark(c->response);
}

static VALUE clogger_alloc(VALUE klass)
{
	struct clogger *c;

	return Data_Make_Struct(klass, struct clogger, clogger_mark, 0, c);
}

static struct clogger *clogger_get(VALUE self)
{
	struct clogger *c;

	Data_Get_Struct(self, struct clogger, c);
	assert(c);
	return c;
}

static VALUE obj_fileno(VALUE obj)
{
	return rb_funcall(obj, rb_intern("fileno"), 0);
}

static VALUE obj_enable_sync(VALUE obj)
{
	return rb_funcall(obj, rb_intern("sync="), 1, Qtrue);
}

/* only for writing to regular files, not stupid crap like NFS  */
static void write_full(int fd, const void *buf, size_t count)
{
	ssize_t r;

	while (count > 0) {
		r = write(fd, buf, count);

		if (r == count) { /* overwhelmingly likely */
			return;
		} else if (r > 0) {
			count -= r;
			buf += r;
		} else {
			if (errno == EINTR || errno == EAGAIN)
				continue; /* poor souls on NFS and like: */
			if (!errno)
				errno = ENOSPC;
			rb_sys_fail("write");
		}
	}
}

/*
 * allow us to use write_full() iff we detect a blocking file
 * descriptor that wouldn't play nicely with Ruby threading/fibers
 */
static int raw_fd(VALUE fileno)
{
#if defined(HAVE_FCNTL) && defined(F_GETFL) && defined(O_NONBLOCK)
	int fd;
	int flags;

	if (NIL_P(fileno))
		return -1;
	fd = NUM2INT(fileno);

	flags = fcntl(fd, F_GETFL);
	if (flags < 0)
		rb_sys_fail("fcntl");

	return (flags & O_NONBLOCK) ? -1 : fd;
#else /* platforms w/o fcntl/F_GETFL/O_NONBLOCK */
	return -1;
#endif /* platforms w/o fcntl/F_GETFL/O_NONBLOCK */
}

/* :nodoc: */
static VALUE clogger_reentrant(VALUE self)
{
	return clogger_get(self)->reentrant == 0 ? Qfalse : Qtrue;
}

/* :nodoc: */
static VALUE clogger_wrap_body(VALUE self)
{
	return clogger_get(self)->wrap_body == 0 ? Qfalse : Qtrue;
}

static void append_status(struct clogger *c)
{
	char buf[sizeof("999")];
	int nr;
	VALUE status = RARRAY_PTR(c->response)[0];

	if (TYPE(status) != T_FIXNUM) {
		status = rb_funcall(status, to_i_id, 0);
		/* no way it's a valid status code (at least not HTTP/1.1) */
		if (TYPE(status) != T_FIXNUM) {
			rb_str_buf_append(c->log_buf, g_dash);
			return;
		}
	}

	nr = NUM2INT(status);
	if (nr >= 100 && nr <= 999) {
		nr = snprintf(buf, sizeof(buf), "%03d", nr);
		assert(nr == 3);
		rb_str_buf_cat(c->log_buf, buf, nr);
	} else {
		/* raise?, swap for 500? */
		rb_str_buf_append(c->log_buf, g_dash);
	}
}

/* this is Rack 1.0.0-compatible, won't try to parse commas in XFF */
static void append_ip(struct clogger *c)
{
	VALUE env = c->env;
	VALUE tmp = rb_hash_aref(env, g_HTTP_X_FORWARDED_FOR);

	if (NIL_P(tmp)) {
		/* can't be faked on any real server, so no escape */
		tmp = rb_hash_aref(env, g_REMOTE_ADDR);
		if (NIL_P(tmp))
			tmp = g_dash;
	} else {
		tmp = byte_xs(tmp);
	}
	rb_str_buf_append(c->log_buf, tmp);
}

static void append_body_bytes_sent(struct clogger *c)
{
	char buf[(sizeof(off_t) * 8) / 3 + 1];
	const char *fmt = sizeof(off_t) == sizeof(long) ? "%ld" : "%lld";
	int nr = snprintf(buf, sizeof(buf), fmt, c->body_bytes_sent);

	assert(nr > 0 && nr < sizeof(buf));
	rb_str_buf_cat(c->log_buf, buf, nr);
}

static void append_tv(struct clogger *c, const VALUE *op, struct timeval *tv)
{
	char buf[sizeof(".000000") + ((sizeof(tv->tv_sec) * 8) / 3)];
	int nr;
	char *fmt = RSTRING_PTR(op[1]);
	int div = NUM2INT(op[2]);

	nr = snprintf(buf, sizeof(buf), fmt,
		      (int)tv->tv_sec, (int)(tv->tv_usec / div));
	assert(nr > 0 && nr < sizeof(buf));
	rb_str_buf_cat(c->log_buf, buf, nr);
}

static void append_request_time_fmt(struct clogger *c, const VALUE *op)
{
	struct timeval now, d;

	gettimeofday(&now, NULL);
	timersub(&now, &c->tv_start, &d);
	append_tv(c, op, &d);
}

static void append_time_fmt(struct clogger *c, const VALUE *op)
{
	struct timeval now;

	gettimeofday(&now, NULL);
	append_tv(c, op, &now);
}

static void append_request_uri(struct clogger *c)
{
	VALUE tmp;

	tmp = rb_hash_aref(c->env, g_REQUEST_URI);
	if (NIL_P(tmp)) {
		tmp = rb_hash_aref(c->env, g_PATH_INFO);
		if (!NIL_P(tmp))
			rb_str_buf_append(c->log_buf, byte_xs(tmp));
		tmp = rb_hash_aref(c->env, g_QUERY_STRING);
		if (!NIL_P(tmp) && RSTRING_LEN(tmp) != 0) {
			rb_str_buf_append(c->log_buf, g_question_mark);
			rb_str_buf_append(c->log_buf, byte_xs(tmp));
		}
	} else {
		rb_str_buf_append(c->log_buf, byte_xs(tmp));
	}
}

static void append_request(struct clogger *c)
{
	VALUE tmp;

	/* REQUEST_METHOD doesn't need escaping, Rack::Lint governs it */
	tmp = rb_hash_aref(c->env, g_REQUEST_METHOD);
	if (!NIL_P(tmp))
		rb_str_buf_append(c->log_buf, tmp);

	rb_str_buf_append(c->log_buf, g_space);

	append_request_uri(c);

	/* HTTP_VERSION can be injected by malicious clients */
	tmp = rb_hash_aref(c->env, g_HTTP_VERSION);
	if (!NIL_P(tmp)) {
		rb_str_buf_append(c->log_buf, g_space);
		rb_str_buf_append(c->log_buf, byte_xs(tmp));
	}
}

static void append_request_length(struct clogger *c)
{
	VALUE tmp = rb_hash_aref(c->env, g_rack_input);
	if (NIL_P(tmp)) {
		rb_str_buf_append(c->log_buf, g_dash);
	} else {
		tmp = rb_funcall(tmp, size_id, 0);
		rb_str_buf_append(c->log_buf, rb_funcall(tmp, to_s_id, 0));
	}
}

static void append_time(struct clogger *c, enum clogger_opcode op, VALUE fmt)
{
	/* you'd have to be a moron to use formats this big... */
	char buf[sizeof("Saturday, November 01, 1970, 00:00:00 PM +0000")];
	size_t nr;
	struct tm tmp;
	time_t t = time(NULL);

	if (op == CL_OP_TIME_LOCAL)
		localtime_r(&t, &tmp);
	else if (op == CL_OP_TIME_UTC)
		gmtime_r(&t, &tmp);
	else
		assert(0 && "unknown op");

	nr = strftime(buf, sizeof(buf), RSTRING_PTR(fmt), &tmp);
	if (nr == 0 || nr == sizeof(buf))
		rb_str_buf_append(c->log_buf, g_dash);
	else
		rb_str_buf_cat(c->log_buf, buf, nr);
}

static void append_pid(struct clogger *c)
{
	char buf[(sizeof(pid_t) * 8) / 3 + 1];
	int nr = snprintf(buf, sizeof(buf), "%d", (int)getpid());

	assert(nr > 0 && nr < sizeof(buf));
	rb_str_buf_cat(c->log_buf, buf, nr);
}

static void append_eval(struct clogger *c, VALUE str)
{
	int state = -1;
	VALUE rv = rb_eval_string_protect(RSTRING_PTR(str), &state);

	rv = state == 0 ? rb_obj_as_string(rv) : g_dash;
	rb_str_buf_append(c->log_buf, rv);
}

static void append_cookie(struct clogger *c, VALUE key)
{
	VALUE cookie;

	if (c->cookies == Qfalse)
		c->cookies = rb_hash_aref(c->env, g_rack_request_cookie_hash);

	if (NIL_P(c->cookies)) {
		cookie = g_dash;
	} else {
		cookie = rb_hash_aref(c->cookies, key);
		if (NIL_P(cookie))
			cookie = g_dash;
	}
	rb_str_buf_append(c->log_buf, cookie);
}

static void append_request_env(struct clogger *c, VALUE key)
{
	VALUE tmp = rb_hash_aref(c->env, key);

	tmp = NIL_P(tmp) ? g_dash : byte_xs(rb_obj_as_string(tmp));
	rb_str_buf_append(c->log_buf, tmp);
}

static void special_var(struct clogger *c, enum clogger_special var)
{
	switch (var) {
	case CL_SP_body_bytes_sent:
		append_body_bytes_sent(c);
		break;
	case CL_SP_status:
		append_status(c);
		break;
	case CL_SP_request:
		append_request(c);
		break;
	case CL_SP_request_length:
		append_request_length(c);
		break;
	case CL_SP_response_length:
		if (c->body_bytes_sent == 0)
			rb_str_buf_append(c->log_buf, g_dash);
		else
			append_body_bytes_sent(c);
		break;
	case CL_SP_ip:
		append_ip(c);
		break;
	case CL_SP_pid:
		append_pid(c);
                break;
	case CL_SP_request_uri:
		append_request_uri(c);
	}
}

static VALUE cwrite(struct clogger *c)
{
	const VALUE ops = sent_headers_ops(c);
	const VALUE *ary = RARRAY_PTR(ops);
	long i = RARRAY_LEN(ops);
	VALUE dst = c->log_buf;

	rb_str_set_len(dst, 0);

	for (; --i >= 0; ary++) {
		const VALUE *op = RARRAY_PTR(*ary);
		enum clogger_opcode opcode = NUM2INT(op[0]);

		switch (opcode) {
		case CL_OP_LITERAL:
			rb_str_buf_append(dst, op[1]);
			break;
		case CL_OP_REQUEST:
			append_request_env(c, op[1]);
			break;
		case CL_OP_RESPONSE:
			/* headers we found already got swapped for literals */
			rb_str_buf_append(dst, g_dash);
			break;
		case CL_OP_SPECIAL:
			special_var(c, NUM2INT(op[1]));
			break;
		case CL_OP_EVAL:
			append_eval(c, op[1]);
			break;
		case CL_OP_TIME_LOCAL:
		case CL_OP_TIME_UTC:
			append_time(c, opcode, op[1]);
			break;
		case CL_OP_REQUEST_TIME:
			append_request_time_fmt(c, op);
			break;
		case CL_OP_TIME:
			append_time_fmt(c, op);
			break;
		case CL_OP_COOKIE:
			append_cookie(c, op[1]);
			break;
		}
	}

	if (c->fd >= 0) {
		write_full(c->fd, RSTRING_PTR(dst), RSTRING_LEN(dst));
	} else {
		VALUE logger = c->logger;

		if (NIL_P(logger))
			logger = rb_hash_aref(c->env, g_rack_errors);
		rb_funcall(logger, ltlt_id, 1, dst);
	}

	return Qnil;
}

/**
 * call-seq:
 *   Clogger.new(app, :logger => $stderr, :format => string) => obj
 *
 * Creates a new Clogger object that wraps +app+.  +:logger+ may
 * be any object that responds to the "<<" method with a string argument.
 */
static VALUE clogger_init(int argc, VALUE *argv, VALUE self)
{
	struct clogger *c = clogger_get(self);
	VALUE o = Qnil;
	VALUE fmt = rb_const_get(mFormat, rb_intern("Common"));

	rb_scan_args(argc, argv, "11", &c->app, &o);
	c->fd = -1;
	c->logger = Qnil;
	c->reentrant = -1; /* auto-detect */

	if (TYPE(o) == T_HASH) {
		VALUE tmp;

		c->logger = rb_hash_aref(o, ID2SYM(rb_intern("logger")));
		if (!NIL_P(c->logger)) {
			rb_rescue(obj_enable_sync, c->logger, 0, 0);
			c->fd = raw_fd(rb_rescue(obj_fileno, c->logger, 0, 0));
		}

		tmp = rb_hash_aref(o, ID2SYM(rb_intern("format")));
		if (!NIL_P(tmp))
			fmt = tmp;
	}

	init_buffers(c);
	c->fmt_ops = rb_funcall(self, rb_intern("compile_format"), 2, fmt, o);

	if (Qtrue == rb_funcall(self, rb_intern("need_response_headers?"),
	                        1, c->fmt_ops))
		c->need_resp = 1;
	if (Qtrue == rb_funcall(self, rb_intern("need_wrap_body?"),
	                        1, c->fmt_ops))
		c->wrap_body = 1;

	return self;
}

static VALUE body_iter_i(VALUE str, VALUE memop)
{
	off_t *len = (off_t *)memop;

	str = rb_obj_as_string(str);
	*len += RSTRING_LEN(str);

	return rb_yield(str);
}

static VALUE wrap_each(struct clogger *c)
{
	VALUE body = RARRAY_PTR(c->response)[2];

	c->body_bytes_sent = 0;
	rb_iterate(rb_each, body, body_iter_i, (VALUE)&c->body_bytes_sent);

	return body;
}

/**
 * call-seq:
 *   clogger.each { |part| socket.write(part) }
 *
 * Delegates the body#each call to the underlying +body+ object
 * while tracking the number of bytes yielded.  This will log
 * the request.
 */
static VALUE clogger_each(VALUE self)
{
	struct clogger *c = clogger_get(self);

	rb_need_block();

	return rb_ensure(wrap_each, (VALUE)c, cwrite, (VALUE)c);
}

/**
 * call-seq:
 *   clogger.close
 *
 * Delegates the body#close call to the underlying +body+ object.
 * This is only used when Clogger is wrapping the +body+ of a Rack
 * response and should be automatically called by the web server.
 */
static VALUE clogger_close(VALUE self)
{
	struct clogger *c = clogger_get(self);

	return rb_funcall(RARRAY_PTR(c->response)[2], close_id, 0);
}

/* :nodoc: */
static VALUE clogger_fileno(VALUE self)
{
	struct clogger *c = clogger_get(self);

	return c->fd < 0 ? Qnil : INT2NUM(c->fd);
}

static void ccall(struct clogger *c, VALUE env)
{
	VALUE rv;

	gettimeofday(&c->tv_start, NULL);
	c->env = env;
	c->cookies = Qfalse;
	rv = rb_funcall(c->app, call_id, 1, env);
	if (TYPE(rv) == T_ARRAY && RARRAY_LEN(rv) == 3) {
		c->response = rv;
	} else {
		c->response = g_bad_app_response;
		cwrite(c);
		rb_raise(rb_eTypeError,
		         "app response not a 3 element Array: %s",
			 RSTRING_PTR(rb_inspect(rv)));
	}
}

/*
 * call-seq:
 *   clogger.call(env) => [ status, headers, body ]
 *
 * calls the wrapped Rack application with +env+, returns the
 * [status, headers, body ] tuplet required by Rack.
 */
static VALUE clogger_call(VALUE self, VALUE env)
{
	struct clogger *c = clogger_get(self);

	if (c->wrap_body) {
		VALUE tmp;

		if (c->reentrant < 0) {
			tmp = rb_hash_aref(env, g_rack_multithread);
			c->reentrant = Qfalse == tmp ? 0 : 1;
		}
		if (c->reentrant) {
			self = rb_obj_dup(self);
			c = clogger_get(self);
		}

		ccall(c, env);
		tmp = rb_ary_dup(c->response);
		rb_ary_store(tmp, 2, self);
		return tmp;
	}

	ccall(c, env);
	cwrite(c);

	return c->response;
}

/* :nodoc */
static VALUE clogger_init_copy(VALUE clone, VALUE orig)
{
	struct clogger *a = clogger_get(orig);
	struct clogger *b = clogger_get(clone);

	memcpy(b, a, sizeof(struct clogger));
	init_buffers(b);

	return clone;
}

#define CONST_GLOBAL_STR2(var, val) do { \
	g_##var = rb_obj_freeze(rb_str_new(val, sizeof(val) - 1)); \
	rb_global_variable(&g_##var); \
} while (0)

#define CONST_GLOBAL_STR(val) CONST_GLOBAL_STR2(val, #val)

static void init_bad_app_response(void)
{
	g_bad_app_response = rb_ary_new();
	rb_ary_store(g_bad_app_response, 0, INT2NUM(500));
	rb_ary_store(g_bad_app_response, 1, rb_obj_freeze(rb_hash_new()));
	rb_ary_store(g_bad_app_response, 2, rb_obj_freeze(rb_ary_new()));
	rb_obj_freeze(g_bad_app_response);
	rb_global_variable(&g_bad_app_response);
}

void Init_clogger_ext(void)
{
	ltlt_id = rb_intern("<<");
	call_id = rb_intern("call");
	each_id = rb_intern("each");
	close_id = rb_intern("close");
	to_i_id = rb_intern("to_i");
	to_s_id = rb_intern("to_s");
	size_id = rb_intern("size");
	cClogger = rb_define_class("Clogger", rb_cObject);
	mFormat = rb_define_module_under(cClogger, "Format");
	rb_define_alloc_func(cClogger, clogger_alloc);
	rb_define_method(cClogger, "initialize", clogger_init, -1);
	rb_define_method(cClogger, "initialize_copy", clogger_init_copy, 1);
	rb_define_method(cClogger, "call", clogger_call, 1);
	rb_define_method(cClogger, "each", clogger_each, 0);
	rb_define_method(cClogger, "close", clogger_close, 0);
	rb_define_method(cClogger, "fileno", clogger_fileno, 0);
	rb_define_method(cClogger, "wrap_body?", clogger_wrap_body, 0);
	rb_define_method(cClogger, "reentrant?", clogger_reentrant, 0);
	CONST_GLOBAL_STR(REMOTE_ADDR);
	CONST_GLOBAL_STR(HTTP_X_FORWARDED_FOR);
	CONST_GLOBAL_STR(REQUEST_METHOD);
	CONST_GLOBAL_STR(PATH_INFO);
	CONST_GLOBAL_STR(QUERY_STRING);
	CONST_GLOBAL_STR(REQUEST_URI);
	CONST_GLOBAL_STR(HTTP_VERSION);
	CONST_GLOBAL_STR2(rack_errors, "rack.errors");
	CONST_GLOBAL_STR2(rack_input, "rack.input");
	CONST_GLOBAL_STR2(rack_multithread, "rack.multithread");
	CONST_GLOBAL_STR2(dash, "-");
	CONST_GLOBAL_STR2(empty, "");
	CONST_GLOBAL_STR2(space, " ");
	CONST_GLOBAL_STR2(question_mark, "?");
	CONST_GLOBAL_STR2(rack_request_cookie_hash, "rack.request.cookie_hash");
	init_bad_app_response();
}
