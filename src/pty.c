#if defined(__FreeBSD__)

  #include <termios.h> // ioctl and constants
  #include <libutil.h> // openpty
  #include <stdlib.h> // ptsname_r
  #include <unistd.h> // tcgetpgrp

#elif defined(__linux__)

  #define _GNU_SOURCE // ptsname_r
  #include <pty.h> // openpty
  #include <stdlib.h> // ptsname_r
  #include <sys/ioctl.h> // ioctl and constants
  #include <unistd.h> // tcgetpgrp, setsid

#elif defined(__APPLE__)

  #include <sys/ioctl.h> // ioctl and constants
  #include <sys/ttycom.h>  // ioctl and constants for TIOCPTYGNAME
  #include <sys/types.h>
  #include <unistd.h> // tcgetpgrp
  #include <util.h> // openpty

  #ifndef tiocsctty
  #define tiocsctty 536900705
  #endif

  #ifndef tiocswinsz
  #define tiocswinsz 2148037735
  #endif

  #ifndef tiocgwinsz
  #define tiocgwinsz 1074295912
  #endif

#else

  #error "unsupported platform"

#endif
