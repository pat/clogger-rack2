#include <ruby.h>
#ifdef HAVE_RUBY_IO_H
#  include <ruby/io.h>
#else
#  include <rubyio.h>
#endif
#include <assert.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <errno.h>
#ifdef HAVE_FCNTL_H
#  include <fcntl.h>
#endif
#ifndef _POSIX_C_SOURCE
#  define _POSIX_C_SOURCE 200112L
#endif
#include <time.h>
#include <stdlib.h>
#include <stdio.h>		/* snprintf */
#include "ruby_1_9_compat.h"
#include "broken_system_compat.h"
#include "blocking_helpers.h"

/*
 * Availability of a monotonic clock needs to be detected at runtime
 * since we could've been built on a different system than we're run
 * under.
 */
static clockid_t hopefully_CLOCK_MONOTONIC;

static void check_clock(void)
{
	struct timespec now;

	hopefully_CLOCK_MONOTONIC = CLOCK_MONOTONIC;

	/* we can't check this reliably at compile time */
	if (clock_gettime(CLOCK_MONOTONIC, &now) == 0)
		return;

	if (clock_gettime(CLOCK_REALTIME, &now) == 0) {
		hopefully_CLOCK_MONOTONIC = CLOCK_REALTIME;
		rb_warn("CLOCK_MONOTONIC not available, "
			"falling back to CLOCK_REALTIME");
	}
	rb_warn("clock_gettime() totally broken, " \
	        "falling back to pure Ruby Clogger");
	rb_raise(rb_eLoadError, "clock_gettime() broken");
}

static void clock_diff(struct timespec *a, const struct timespec *b)
{
	a->tv_sec -= b->tv_sec;
	a->tv_nsec -= b->tv_nsec;
	if (a->tv_nsec < 0) {
		--a->tv_sec;
		a->tv_nsec += 1000000000;
	}
}

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
	CL_SP_request_uri,
	CL_SP_time_iso8601,
	CL_SP_time_local,
	CL_SP_time_utc
};

struct clogger {
	VALUE app;

	VALUE fmt_ops;
	VALUE logger;
	VALUE log_buf;

	VALUE env;
	VALUE cookies;
	VALUE status;
	VALUE headers;
	VALUE body;

	off_t body_bytes_sent;
	struct timespec ts_start;

	int fd;
	int wrap_body;
	int need_resp;
	int reentrant; /* tri-state, -1:auto, 1/0 true/false */
};

static ID write_id;
static ID ltlt_id;
static ID call_id;
static ID close_id;
static ID to_i_id;
static ID to_s_id;
static ID size_id;
static ID sq_brace_id;
static ID new_id;
static ID to_path_id;
static ID respond_to_id;
static VALUE cClogger;
static VALUE mFormat;
static VALUE cHeaderHash;

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
static VALUE g_space;
static VALUE g_question_mark;
static VALUE g_rack_request_cookie_hash;

#define LOG_BUF_INIT_SIZE 128

static void init_buffers(struct clogger *c)
{
	c->log_buf = rb_str_buf_new(LOG_BUF_INIT_SIZE);
}

static inline int need_escape(unsigned c)
{
	assert(c <= 0xff);
	return !!(c == '\'' || c == '"' || c <= 0x1f || c >= 0x7f);
}

/* we are encoding-agnostic, clients can send us all sorts of junk */
static VALUE byte_xs(VALUE obj)
{
	static const char esc[] = "0123456789ABCDEF";
	unsigned char *new_ptr;
	VALUE from = rb_obj_as_string(obj);
	const unsigned char *ptr = (const unsigned char *)RSTRING_PTR(from);
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

	rv = rb_str_new(NULL, new_len);
	new_ptr = (unsigned char *)RSTRING_PTR(rv);
	ptr = (const unsigned char *)RSTRING_PTR(from);
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

	RB_GC_GUARD(from);
	return rv;
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
	rb_gc_mark(c->status);
	rb_gc_mark(c->headers);
	rb_gc_mark(c->body);
}

static VALUE clogger_alloc(VALUE klass)
{
	struct clogger *c;

	return Data_Make_Struct(klass, struct clogger, clogger_mark, -1, c);
}

static struct clogger *clogger_get(VALUE self)
{
	struct clogger *c;

	Data_Get_Struct(self, struct clogger, c);
	assert(c);
	return c;
}

/* only for writing to regular files, not stupid crap like NFS  */
static void write_full(int fd, const char *buf, size_t count)
{
	ssize_t r;

	while (count > 0) {
		r = nogvl_write(fd, buf, count);

		if ((size_t)r == count) { /* overwhelmingly likely */
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
static int raw_fd(VALUE my_fd)
{
#if defined(HAVE_FCNTL) && defined(F_GETFL) && defined(O_NONBLOCK)
	int fd;
	int flags;

	if (NIL_P(my_fd))
		return -1;
	fd = NUM2INT(my_fd);

	flags = fcntl(fd, F_GETFL);
	if (flags < 0)
		rb_sys_fail("fcntl");

	if (flags & O_NONBLOCK) {
		struct stat sb;

		if (fstat(fd, &sb) < 0)
			return -1;

		/* O_NONBLOCK is no-op for regular files: */
		if (! S_ISREG(sb.st_mode))
			return -1;
	}
	return fd;
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
	VALUE status = c->status;

	if (TYPE(status) != T_FIXNUM) {
		status = rb_funcall(status, to_i_id, 0);
		/* no way it's a valid status code (at least not HTTP/1.1) */
		if (TYPE(status) != T_FIXNUM) {
			rb_str_buf_append(c->log_buf, g_dash);
			return;
		}
	}

	nr = FIX2INT(status);
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

	assert(nr > 0 && nr < (int)sizeof(buf));
	rb_str_buf_cat(c->log_buf, buf, nr);
}

static void append_ts(struct clogger *c, VALUE op, struct timespec *ts)
{
	char buf[sizeof(".000000") + ((sizeof(ts->tv_sec) * 8) / 3)];
	int nr;
	char *fmt = RSTRING_PTR(rb_ary_entry(op, 1));
	int ndiv = NUM2INT(rb_ary_entry(op, 2));
	int usec = ts->tv_nsec / 1000;

	nr = snprintf(buf, sizeof(buf), fmt,
		      (int)ts->tv_sec, (int)(usec / ndiv));
	assert(nr > 0 && nr < (int)sizeof(buf));
	rb_str_buf_cat(c->log_buf, buf, nr);
}

static void append_request_time_fmt(struct clogger *c, VALUE op)
{
	struct timespec now;

	clock_gettime(hopefully_CLOCK_MONOTONIC, &now);
	clock_diff(&now, &c->ts_start);
	append_ts(c, op, &now);
}

static void append_time_fmt(struct clogger *c, VALUE op)
{
	struct timespec now;
	int r = clock_gettime(CLOCK_REALTIME, &now);

	if (unlikely(r != 0))
		rb_sys_fail("clock_gettime(CLOCK_REALTIME)");
	append_ts(c, op, &now);
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

static long local_gmtoffset(struct tm *tm)
{
	time_t t = time(NULL);

	tzset();
	localtime_r(&t, tm);

/*
 * HAVE_STRUCT_TM_TM_GMTOFF may be defined in Ruby headers
 * HAVE_ST_TM_GMTOFF is defined ourselves.
 */
#if defined(HAVE_STRUCT_TM_TM_GMTOFF) || defined(HAVE_ST_TM_GMTOFF)
	return tm->tm_gmtoff / 60;
#else
	return -(tm->tm_isdst ? timezone - 3600 : timezone) / 60;
#endif
}

static void append_time_iso8601(struct clogger *c)
{
	char buf[sizeof("1970-01-01T00:00:00+00:00")];
	struct tm tm;
	int nr;
	long gmtoff = local_gmtoffset(&tm);

	nr = snprintf(buf, sizeof(buf),
	              "%4d-%02d-%02dT%02d:%02d:%02d%c%02d:%02d",
	              tm.tm_year + 1900, tm.tm_mon + 1,
	              tm.tm_mday, tm.tm_hour,
	              tm.tm_min, tm.tm_sec,
	              gmtoff < 0 ? '-' : '+',
	              abs(gmtoff / 60), abs(gmtoff % 60));
	assert(nr == (sizeof(buf) - 1) && "snprintf fail");
	rb_str_buf_cat(c->log_buf, buf, sizeof(buf) - 1);
}

static const char months[] = "Jan\0Feb\0Mar\0Apr\0May\0Jun\0"
                             "Jul\0Aug\0Sep\0Oct\0Nov\0Dec";

static void append_time_local(struct clogger *c)
{
	char buf[sizeof("01/Jan/1970:00:00:00 +0000")];
	struct tm tm;
	int nr;
	long gmtoff = local_gmtoffset(&tm);

	nr = snprintf(buf, sizeof(buf),
	              "%02d/%s/%d:%02d:%02d:%02d %c%02d%02d",
	              tm.tm_mday, months + (tm.tm_mon * sizeof("Jan")),
	              tm.tm_year + 1900, tm.tm_hour,
	              tm.tm_min, tm.tm_sec,
	              gmtoff < 0 ? '-' : '+',
	              abs(gmtoff / 60), abs(gmtoff % 60));
	assert(nr == (sizeof(buf) - 1) && "snprintf fail");
	rb_str_buf_cat(c->log_buf, buf, sizeof(buf) - 1);
}

static void append_time_utc(struct clogger *c)
{
	char buf[sizeof("01/Jan/1970:00:00:00 +0000")];
	struct tm tm;
	int nr;
	time_t t = time(NULL);

	gmtime_r(&t, &tm);
	nr = snprintf(buf, sizeof(buf),
	              "%02d/%s/%d:%02d:%02d:%02d +0000",
	              tm.tm_mday, months + (tm.tm_mon * sizeof("Jan")),
	              tm.tm_year + 1900, tm.tm_hour,
	              tm.tm_min, tm.tm_sec);
	assert(nr == (sizeof(buf) - 1) && "snprintf fail");
	rb_str_buf_cat(c->log_buf, buf, sizeof(buf) - 1);
}

static void
append_time(struct clogger *c, enum clogger_opcode op, VALUE fmt, VALUE buf)
{
	char *buf_ptr = RSTRING_PTR(buf);
	size_t buf_size = RSTRING_LEN(buf) + 1; /* "\0" */
	size_t nr;
	struct tm tmp;
	time_t t = time(NULL);

	if (op == CL_OP_TIME_LOCAL)
		localtime_r(&t, &tmp);
	else if (op == CL_OP_TIME_UTC)
		gmtime_r(&t, &tmp);
	else
		assert(0 && "unknown op");

	nr = strftime(buf_ptr, buf_size, RSTRING_PTR(fmt), &tmp);
	assert(nr < buf_size && "time format too small!");
	rb_str_buf_cat(c->log_buf, buf_ptr, nr);
}

static void append_pid(struct clogger *c)
{
	char buf[(sizeof(pid_t) * 8) / 3 + 1];
	int nr = snprintf(buf, sizeof(buf), "%d", (int)getpid());

	assert(nr > 0 && nr < (int)sizeof(buf));
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
		cookie = NIL_P(cookie) ? g_dash : byte_xs(cookie);
	}
	rb_str_buf_append(c->log_buf, cookie);
}

static void append_request_env(struct clogger *c, VALUE key)
{
	VALUE tmp = rb_hash_aref(c->env, key);

	tmp = NIL_P(tmp) ? g_dash : byte_xs(tmp);
	rb_str_buf_append(c->log_buf, tmp);
}

static void append_response(struct clogger *c, VALUE key)
{
	VALUE v;

	assert(rb_obj_is_kind_of(c->headers, cHeaderHash) && "not HeaderHash");

	v = rb_funcall(c->headers, sq_brace_id, 1, key);
	v = NIL_P(v) ? g_dash : byte_xs(v);
	rb_str_buf_append(c->log_buf, v);
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
		break;
	case CL_SP_time_iso8601:
		append_time_iso8601(c);
		break;
	case CL_SP_time_local:
		append_time_local(c);
		break;
	case CL_SP_time_utc:
		append_time_utc(c);
	}
}

static VALUE cwrite(struct clogger *c)
{
	const VALUE ops = c->fmt_ops;
	long i;
	long len = RARRAY_LEN(ops);
	VALUE dst = c->log_buf;

	rb_str_set_len(dst, 0);

	for (i = 0; i < len; i++) {
		VALUE op = rb_ary_entry(ops, i);
		enum clogger_opcode opcode = FIX2INT(rb_ary_entry(op, 0));
		VALUE op1 = rb_ary_entry(op, 1);

		switch (opcode) {
		case CL_OP_LITERAL:
			rb_str_buf_append(dst, op1);
			break;
		case CL_OP_REQUEST:
			append_request_env(c, op1);
			break;
		case CL_OP_RESPONSE:
			append_response(c, op1);
			break;
		case CL_OP_SPECIAL:
			special_var(c, FIX2INT(op1));
			break;
		case CL_OP_EVAL:
			append_eval(c, op1);
			break;
		case CL_OP_TIME_LOCAL:
		case CL_OP_TIME_UTC: {
			VALUE arg2 = rb_ary_entry(op, 2);
			append_time(c, opcode, op1, arg2);
		}
			break;
		case CL_OP_REQUEST_TIME:
			append_request_time_fmt(c, op);
			break;
		case CL_OP_TIME:
			append_time_fmt(c, op);
			break;
		case CL_OP_COOKIE:
			append_cookie(c, op1);
			break;
		}
	}

	if (c->fd >= 0) {
		write_full(c->fd, RSTRING_PTR(dst), RSTRING_LEN(dst));
	} else {
		VALUE logger = c->logger;

		if (NIL_P(logger)) {
			logger = rb_hash_aref(c->env, g_rack_errors);
                        rb_funcall(logger, write_id, 1, dst);
                } else {
			rb_funcall(logger, ltlt_id, 1, dst);
		}
	}

	return Qnil;
}

static VALUE clogger_write(VALUE self)
{
	return cwrite(clogger_get(self));
}

static void init_logger(struct clogger *c, VALUE path)
{
	ID id;

	if (!NIL_P(path) && !NIL_P(c->logger))
		rb_raise(rb_eArgError, ":logger and :path are independent");
	if (!NIL_P(path)) {
		VALUE ab = rb_str_new2("ab");
		id = rb_intern("open");
		c->logger = rb_funcall(rb_cFile, id, 2, path, ab);
	}

	id = rb_intern("sync=");
	if (rb_respond_to(c->logger, id))
		rb_funcall(c->logger, id, 1, Qtrue);

	id = rb_intern("fileno");
	if (rb_respond_to(c->logger, id))
		c->fd = raw_fd(rb_funcall(c->logger, id, 0));
}

/**
 * call-seq:
 *   Clogger.new(app, :logger => $stderr, :format => string) => obj
 *
 * Creates a new Clogger object that wraps +app+.  +:logger+ may
 * be any object that responds to the "<<" method with a string argument.
 * Instead of +:logger+, +:path+ may be specified to be a :path of a File
 * that will be opened in append mode.
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

		tmp = rb_hash_aref(o, ID2SYM(rb_intern("path")));
		c->logger = rb_hash_aref(o, ID2SYM(rb_intern("logger")));
		init_logger(c, tmp);

		tmp = rb_hash_aref(o, ID2SYM(rb_intern("format")));
		if (!NIL_P(tmp))
			fmt = tmp;

		tmp = rb_hash_aref(o, ID2SYM(rb_intern("reentrant")));
		switch (TYPE(tmp)) {
		case T_TRUE:
			c->reentrant = 1;
			break;
		case T_FALSE:
			c->reentrant = 0;
		case T_NIL:
			break;
		default:
			rb_raise(rb_eArgError, ":reentrant must be boolean");
		}
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

static VALUE body_iter_i(VALUE str, VALUE self)
{
	struct clogger *c = clogger_get(self);

	str = rb_obj_as_string(str);
	c->body_bytes_sent += RSTRING_LEN(str);

	return rb_yield(str);
}

static VALUE body_close(VALUE self)
{
	struct clogger *c = clogger_get(self);

	if (rb_respond_to(c->body, close_id))
		return rb_funcall(c->body, close_id, 0);
	return Qnil;
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
	c->body_bytes_sent = 0;
	rb_iterate(rb_each, c->body, body_iter_i, self);

	return self;
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

	return rb_ensure(body_close, self, clogger_write, self);
}

/* :nodoc: */
static VALUE clogger_fileno(VALUE self)
{
	struct clogger *c = clogger_get(self);

	return c->fd < 0 ? Qnil : INT2NUM(c->fd);
}

static VALUE ccall(struct clogger *c, VALUE env)
{
	VALUE rv;

	clock_gettime(hopefully_CLOCK_MONOTONIC, &c->ts_start);
	c->env = env;
	c->cookies = Qfalse;
	rv = rb_funcall(c->app, call_id, 1, env);
	if (TYPE(rv) == T_ARRAY && RARRAY_LEN(rv) == 3) {
		c->status = rb_ary_entry(rv, 0);
		c->headers = rb_ary_entry(rv, 1);
		c->body = rb_ary_entry(rv, 2);

		rv = rb_ary_dup(rv);
		if (c->need_resp &&
                    ! rb_obj_is_kind_of(c->headers, cHeaderHash)) {
			c->headers = rb_funcall(cHeaderHash, new_id, 1,
			                        c->headers);
			rb_ary_store(rv, 1, c->headers);
		}
	} else {
		VALUE tmp = rb_inspect(rv);

		c->status = INT2FIX(500);
		c->headers = c->body = rb_ary_new();
		cwrite(c);
		rb_raise(rb_eTypeError,
		         "app response not a 3 element Array: %s",
			 RSTRING_PTR(tmp));
		RB_GC_GUARD(tmp);
	}

	return rv;
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
	VALUE rv;

	env = rb_check_convert_type(env, T_HASH, "Hash", "to_hash");

	if (c->wrap_body) {
		/* XXX: we assume the existence of the GVL here: */
		if (c->reentrant < 0) {
			VALUE tmp = rb_hash_aref(env, g_rack_multithread);
			c->reentrant = Qfalse == tmp ? 0 : 1;
		}

		if (c->reentrant) {
			self = rb_obj_dup(self);
			c = clogger_get(self);
		}

		rv = ccall(c, env);
		assert(!OBJ_FROZEN(rv) && "frozen response array");
		rb_ary_store(rv, 2, self);

		return rv;
	}

	rv = ccall(c, env);
	cwrite(c);

	return rv;
}

static void duplicate_buffers(VALUE ops)
{
	long i;
	long len = RARRAY_LEN(ops);

	for (i = 0; i < len; i++) {
		VALUE op = rb_ary_entry(ops, i);
		enum clogger_opcode opcode = FIX2INT(rb_ary_entry(op, 0));

		if (opcode == CL_OP_TIME_LOCAL || opcode == CL_OP_TIME_UTC) {
			VALUE buf = rb_ary_entry(op, 2);
			Check_Type(buf, T_STRING);
			buf = rb_str_dup(buf);
			rb_str_modify(buf); /* trigger copy-on-write */
			rb_ary_store(op, 2, buf);
		}
	}
}

/* :nodoc: */
static VALUE clogger_init_copy(VALUE clone, VALUE orig)
{
	struct clogger *a = clogger_get(orig);
	struct clogger *b = clogger_get(clone);

	memcpy(b, a, sizeof(struct clogger));
	init_buffers(b);
	duplicate_buffers(b->fmt_ops);

	return clone;
}

#define CONST_GLOBAL_STR2(var, val) do { \
	g_##var = rb_obj_freeze(rb_str_new(val, sizeof(val) - 1)); \
	rb_global_variable(&g_##var); \
} while (0)

#define CONST_GLOBAL_STR(val) CONST_GLOBAL_STR2(val, #val)

/*
 * call-seq:
 *   clogger.respond_to?(:to_path) => true or false
 *   clogger.respond_to?(:close)  => true
 *
 * used to delegate +:to_path+ checks for Rack webservers that optimize
 * static file serving
 */
static VALUE respond_to(VALUE self, VALUE method)
{
	struct clogger *c = clogger_get(self);
	ID id = rb_to_id(method);

	if (close_id == id)
		return Qtrue;
	return rb_respond_to(c->body, id);
}

/*
 * call-seq:
 *   clogger.to_path
 *
 * used to proxy +:to_path+ method calls to the wrapped response body.
 */
static VALUE to_path(VALUE self)
{
	struct clogger *c = clogger_get(self);
	struct stat sb;
	int rv;
	VALUE path = rb_funcall(c->body, to_path_id, 0);
	const char *cpath = StringValueCStr(path);
	unsigned devfd;

	/*
	 * Rainbows! can use "/dev/fd/%u" in to_path output to avoid
	 * extra open() syscalls, too.
	 */
	if (sscanf(cpath, "/dev/fd/%u", &devfd) == 1)
		rv = fstat((int)devfd, &sb);
	else
		rv = nogvl_stat(cpath, &sb);

	/*
	 * calling this method implies the web server will bypass
	 * the each method where body_bytes_sent is calculated,
	 * so we stat and set that value here.
	 */
	c->body_bytes_sent = rv == 0 ? sb.st_size : 0;
	return path;
}

/* :nodoc: */
static VALUE body(VALUE self)
{
	return clogger_get(self)->body;
}

void Init_clogger_ext(void)
{
	VALUE tmp;

	check_clock();

	write_id = rb_intern("write");
	ltlt_id = rb_intern("<<");
	call_id = rb_intern("call");
	close_id = rb_intern("close");
	to_i_id = rb_intern("to_i");
	to_s_id = rb_intern("to_s");
	size_id = rb_intern("size");
	sq_brace_id = rb_intern("[]");
	new_id = rb_intern("new");
	to_path_id = rb_intern("to_path");
	respond_to_id = rb_intern("respond_to?");
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
	rb_define_method(cClogger, "to_path", to_path, 0);
	rb_define_method(cClogger, "respond_to?", respond_to, 1);
	rb_define_method(cClogger, "body", body, 0);
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
	CONST_GLOBAL_STR2(space, " ");
	CONST_GLOBAL_STR2(question_mark, "?");
	CONST_GLOBAL_STR2(rack_request_cookie_hash, "rack.request.cookie_hash");

	tmp = rb_const_get(rb_cObject, rb_intern("Rack"));
	tmp = rb_const_get(tmp, rb_intern("Utils"));
	cHeaderHash = rb_const_get(tmp, rb_intern("HeaderHash"));
}
