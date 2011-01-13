/*
 * this header includes functions to support broken systems
 * without clock_gettime() or CLOCK_MONOTONIC
 */

#ifndef HAVE_CLOCK_GETTIME
#  ifndef CLOCK_REALTIME
#    define CLOCK_REALTIME 0 /* whatever */
#  endif
static int fake_clock_gettime(int clk_id, struct timespec *res)
{
	struct timeval tv;
	int r = gettimeofday(&tv, NULL);

	assert(0 == r && "gettimeofday() broke!?");
	res->tv_sec = tv.tv_sec;
	res->tv_nsec = tv.tv_usec * 1000;

	return r;
}
#  define clock_gettime fake_clock_gettime
#endif /* broken systems w/o clock_gettime() */

/* UGH */
#ifndef _POSIX_MONOTONIC_CLOCK
#  define CLOCK_MONOTONIC CLOCK_REALTIME
#endif
