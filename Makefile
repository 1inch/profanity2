CC=g++
CDEFINES=
SOURCES=Dispatcher.cpp Mode.cpp precomp.cpp profanity.cpp SpeedSample.cpp
OBJECTS=$(SOURCES:.cpp=.o)

# On Windows the OS environment variable is always set to Windows_NT.
# Checking it first avoids calling `uname`, which is unavailable outside
# of MSYS2/Cygwin shells (e.g. when using mingw32-make from cmd.exe).
ifeq ($(OS),Windows_NT)
	EXECUTABLE=profanity2.exe
	# -mcmodel=large is not reliably supported by MinGW GCC on Windows
	# targets, and htonl/ntohl live in ws2_32 there.
	LDFLAGS=-s -lOpenCL -lws2_32
	CFLAGS=-c -std=c++11 -Wall -mmmx -O2
	# MSYSTEM is set inside MSYS2 shells, where unix commands are available.
	ifdef MSYSTEM
		RM=rm -f
	else
		RM=del /Q
	endif
else
	EXECUTABLE=profanity2.x64
	RM=rm -f
	UNAME_S := $(shell uname -s)
	ifeq ($(UNAME_S),Darwin)
		LDFLAGS=-framework OpenCL
		CFLAGS=-c -std=c++11 -Wall -O2
	else
		LDFLAGS=-s -lOpenCL -mcmodel=large
		CFLAGS=-c -std=c++11 -Wall -mmmx -O2 -mcmodel=large
	endif
endif

all: $(SOURCES) $(EXECUTABLE)

$(EXECUTABLE): $(OBJECTS)
	$(CC) $(OBJECTS) $(LDFLAGS) -o $@

.cpp.o:
	$(CC) $(CFLAGS) $(CDEFINES) $< -o $@

clean:
	$(RM) *.o
