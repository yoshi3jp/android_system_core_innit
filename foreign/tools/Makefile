# Innit foreign menuconfig tools

CC ?= cc
PKG_CONFIG ?= pkg-config

NCURSES_CFLAGS := $(shell $(PKG_CONFIG) --cflags ncursesw 2>/dev/null)
NCURSES_LIBS   := $(shell $(PKG_CONFIG) --libs ncursesw 2>/dev/null)

ifeq ($(strip $(NCURSES_LIBS)),)
NCURSES_LIBS := -lncursesw
endif

CFLAGS ?= -O2 -Wall -Wextra -std=c11

.PHONY: all clean menuconfig

all: innit-menuconfig

innit-menuconfig: innit_menuconfig.c
	$(CC) $(CFLAGS) $(NCURSES_CFLAGS) -o $@ $< $(NCURSES_LIBS)

menuconfig: innit-menuconfig
	./innit-menuconfig

clean:
	rm -f innit-menuconfig
