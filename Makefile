CC=g++
CDEFINES=

SRCDIR=src
KERNELDIR=kernels
OBJDIR=build
BINDIR=bin

SOURCES=$(addprefix $(SRCDIR)/,Dispatcher.cpp Mode.cpp precomp.cpp profanity.cpp SpeedSample.cpp)
OBJECTS=$(patsubst $(SRCDIR)/%.cpp,$(OBJDIR)/%.o,$(SOURCES))

# The kernels are copied next to the binary because that is the first place
# profanity2 looks for them, which makes bin/ self-contained: it can be copied
# elsewhere and run from any working directory.
KERNELS=$(addprefix $(BINDIR)/,keccak.cl profanity.cl)

# On Windows the OS environment variable is always set to Windows_NT.
# Checking it first avoids calling `uname`, which is unavailable outside
# of MSYS2/Cygwin shells (e.g. when using mingw32-make from cmd.exe).
ifeq ($(OS),Windows_NT)
	EXECUTABLE=$(BINDIR)/profanity2.exe
	# -mcmodel=large is not reliably supported by MinGW GCC on Windows
	# targets, and htonl/ntohl live in ws2_32 there.
	# -static bundles the MinGW runtimes (libstdc++, libgcc, winpthread) so
	# the exe runs outside the MSYS2 shell; OpenCL.dll itself must stay
	# dynamic (it is the system ICD loader), but with -static the linker
	# skips .dll.a import libs for -lOpenCL, hence the explicit -l: name.
	LDFLAGS=-s -static -l:libOpenCL.dll.a -lws2_32
	CFLAGS=-c -std=c++11 -Wall -mmmx -O2
	# MSYSTEM is set inside MSYS2 shells, where unix commands are available.
	# Outside of them the recipes have to speak cmd.exe, which wants
	# backslashes and refuses to mkdir a directory that already exists.
	ifdef MSYSTEM
		MKDIR=mkdir -p $1
		COPY=cp -f $1 $2
		RMDIR=rm -rf $1
	else
		MKDIR=if not exist "$(subst /,\,$1)" mkdir "$(subst /,\,$1)"
		COPY=copy /Y "$(subst /,\,$1)" "$(subst /,\,$2)" >NUL
		RMDIR=if exist "$(subst /,\,$1)" rmdir /S /Q "$(subst /,\,$1)"
	endif
else
	EXECUTABLE=$(BINDIR)/profanity2.x64
	MKDIR=mkdir -p $1
	COPY=cp -f $1 $2
	RMDIR=rm -rf $1
	UNAME_S := $(shell uname -s)
	ifeq ($(UNAME_S),Darwin)
		LDFLAGS=-framework OpenCL
		CFLAGS=-c -std=c++11 -Wall -O2
	else
		LDFLAGS=-s -lOpenCL -mcmodel=large
		CFLAGS=-c -std=c++11 -Wall -mmmx -O2 -mcmodel=large
	endif
endif

.PHONY: all clean

all: $(EXECUTABLE) $(KERNELS)

$(EXECUTABLE): $(OBJECTS) | $(BINDIR)
	$(CC) $(OBJECTS) $(LDFLAGS) -o $@

$(OBJDIR)/%.o: $(SRCDIR)/%.cpp | $(OBJDIR)
	$(CC) $(CFLAGS) $(CDEFINES) $< -o $@

$(BINDIR)/%.cl: $(KERNELDIR)/%.cl | $(BINDIR)
	$(call COPY,$<,$@)

$(OBJDIR) $(BINDIR):
	$(call MKDIR,$@)

clean:
	$(call RMDIR,$(OBJDIR))
	$(call RMDIR,$(BINDIR))
