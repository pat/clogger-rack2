/* Ruby 1.8.6+ macros (for compatibility with Ruby 1.9) */
#ifndef RSTRING_PTR
#  define RSTRING_PTR(s) (RSTRING(s)->ptr)
#endif
#ifndef RSTRING_LEN
#  define RSTRING_LEN(s) (RSTRING(s)->len)
#endif
#ifndef RARRAY_PTR
#  define RARRAY_PTR(s) (RARRAY(s)->ptr)
#endif
#ifndef RARRAY_LEN
#  define RARRAY_LEN(s) (RARRAY(s)->len)
#endif
#ifndef RSTRUCT_PTR
#  define RSTRUCT_PTR(s) (RSTRUCT(s)->ptr)
#endif
#ifndef RSTRUCT_LEN
#  define RSTRUCT_LEN(s) (RSTRUCT(s)->len)
#endif

#ifndef HAVE_RB_STR_SET_LEN
/* this is taken from Ruby 1.8.7, 1.8.6 may not have it */
static void rb_18_str_set_len(VALUE str, long len)
{
	RSTRING(str)->len = len;
	RSTRING(str)->ptr[len] = '\0';
}
#define rb_str_set_len(str,len) rb_18_str_set_len(str,len)
#endif

#if ! HAVE_RB_IO_T
#  define rb_io_t OpenFile
#endif

#ifdef GetReadFile
#  define FPTR_TO_FD(fptr) (fileno(GetReadFile(fptr)))
#else
#  if !HAVE_RB_IO_T || (RUBY_VERSION_MAJOR == 1 && RUBY_VERSION_MINOR == 8)
#    define FPTR_TO_FD(fptr) fileno(fptr->f)
#  else
#    define FPTR_TO_FD(fptr) fptr->fd
#  endif
#endif

static int my_fileno(VALUE io)
{
	rb_io_t *fptr;

	for (;;) {
		switch (TYPE(io)) {
		case T_FILE: {
			GetOpenFile(io, fptr);
			return FPTR_TO_FD(fptr);
		}
		default:
			io = rb_convert_type(io, T_FILE, "IO", "to_io");
			/* retry */
		}
	}
}
