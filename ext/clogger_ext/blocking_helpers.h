#ifdef HAVE_RB_THREAD_BLOCKING_REGION
struct stat_args { const char *path; struct stat *buf; };
static VALUE ng_stat(void *ptr)
{
	struct stat_args *a = ptr;
	return (VALUE)stat(a->path, a->buf);
}
static int my_stat(const char *path, struct stat *buf)
{
	struct stat_args a;

	a.path = path;
	a.buf = buf;
	return (int)rb_thread_blocking_region(ng_stat, &a, RUBY_UBF_IO, 0);
}
#ifndef HAVE_RB_THREAD_IO_BLOCKING_REGION
#  define rb_thread_io_blocking_region(fn,data,fd) \
           rb_thread_blocking_region((fn),(data), RUBY_UBF_IO, 0)
#endif

struct fstat_args { int fd; struct stat *buf; };
static VALUE ng_fstat(void *ptr)
{
	struct fstat_args *a = ptr;
	return (VALUE)fstat(a->fd, a->buf);
}

static int my_fstat(int fd, struct stat *buf)
{
	struct fstat_args a;

	a.fd = fd;
	a.buf = buf;
	return (int)rb_thread_io_blocking_region(ng_fstat, &a, fd);
}

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
#  define stat(fd,buf) my_stat((fd),(buf))
#  define fstat(fd,buf) my_fstat((fd),(buf))
#  define write(fd,buf,count) my_write((fd),(buf),(count))
#endif
