#if defined(HAVE_RB_THREAD_CALL_WITHOUT_GVL) && defined(HAVE_RUBY_THREAD_H)
/* Ruby 2.0+ */
#  include <ruby/thread.h>
#  define WITHOUT_GVL(fn,a,ubf,b) \
        rb_thread_call_without_gvl((fn),(a),(ubf),(b))
#elif defined(HAVE_RB_THREAD_BLOCKING_REGION)
typedef VALUE (*my_blocking_fn_t)(void*);
#  define WITHOUT_GVL(fn,a,ubf,b) \
	rb_thread_blocking_region((my_blocking_fn_t)(fn),(a),(ubf),(b))
#endif

#ifdef WITHOUT_GVL
struct stat_args { int err; const char *path; struct stat *buf; };
static void * ng_stat(void *ptr)
{
	struct stat_args *a = ptr;
	a->err = stat(a->path, a->buf);
	return NULL;
}

static int my_stat(const char *path, struct stat *buf)
{
	struct stat_args a;

	a.path = path;
	a.buf = buf;
	WITHOUT_GVL(ng_stat, &a, RUBY_UBF_IO, 0);
	return a.err;
}

#ifndef HAVE_RB_THREAD_IO_BLOCKING_REGION
#  define rb_thread_io_blocking_region(fn,data,fd) \
           WITHOUT_GVL((fn),(data), RUBY_UBF_IO, 0)
#else
  VALUE rb_thread_io_blocking_region(VALUE(*)(void *), void *, int);
#endif

struct write_args { int fd; const void *buf; size_t count; };
static VALUE ng_write(void *ptr)
{
	struct write_args *a = ptr;

	return (VALUE)write(a->fd, a->buf, a->count);
}
static ssize_t my_write(int fd, const void *buf, size_t count)
{
	struct write_args a;
	ssize_t r;

	a.fd = fd;
	a.buf = buf;
	a.count = count;
	r = (ssize_t)rb_thread_io_blocking_region(ng_write, &a, fd);

	return r;
}
#  define stat(path,buf) my_stat((path),(buf))
#  define write(fd,buf,count) my_write((fd),(buf),(count))
#endif /* !WITHOUT_GVL */
