#define _XOPEN_SOURCE 700

#include <ctype.h>
#include <errno.h>
#include <dirent.h>
#include <sys/utsname.h>
#include <limits.h>
#include <ncurses.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#define VALUE_MAX 1024

enum field_type {
    FIELD_STRING,
    FIELD_PATH,
    FIELD_CHOICE,
};

struct choice_list {
    const char **items;
    size_t count;
};

struct config_item {
    const char *key;
    const char *prompt;
    const char *help;
    enum field_type type;
    const char *defval;
    char value[VALUE_MAX];
    struct choice_list choices;
};

static const char *yes_no_choices[] = { "yes", "no" };
static const char *auto_yes_no_choices[] = { "auto", "yes", "no" };
static const char *arch_choices[] = { "aarch64", "arm" };
static const char *triple_choices[] = { "aarch64-linux-android", "armv7a-linux-androideabi" };
static const char *libdir_choices[] = { "lib64", "lib" };
static const char *variant_choices[] = { "second_stage", "policy_check", "both" };

static char repo_root[PATH_MAX];
static char config_path[PATH_MAX];
static char jobs_default_value[32] = "1";

static struct config_item items[] = {
    {
        .key = "INNIT_ROOT",
        .prompt = "Innit repository root",
        .help = "Filtered Innit repo containing init/ and foreign/.",
        .type = FIELD_PATH,
        .defval = "../..",
    },
    {
        .key = "AOSP_QUARRY",
        .prompt = "Sparse AOSP source/header quarry",
        .help = "Sparse checkout used as source/header quarry. Expected minimum: system/core and external/tinyxml2.",
        .type = FIELD_PATH,
        .defval = "~/Development/innit-aosp-quarry",
    },
    {
        .key = "RECOVERY_SYSTEM",
        .prompt = "Recovery-derived /system root",
        .help = "Recovery /system tree whose lib64 ABI is used for linking and runtime.",
        .type = FIELD_PATH,
        .defval = "~/Development/dsgsi/android/ramdisk/system",
    },
    {
        .key = "DSGSI_ROOT",
        .prompt = "DS_GSI project root",
        .help = "DS_GSI root used by staging helper scripts.",
        .type = FIELD_PATH,
        .defval = "~/Development/dsgsi",
    },
    {
        .key = "NDK_ROOT",
        .prompt = "Android NDK root",
        .help = "Android NDK containing toolchains/llvm/prebuilt/<host-tag>/bin.",
        .type = FIELD_PATH,
        .defval = "~/Android/Sdk/ndk/26.3.11579264",
    },
    {
        .key = "NDK_HOST_TAG",
        .prompt = "NDK host prebuilt tag",
        .help = "Use auto to detect from the available NDK prebuilt directory, or set linux-x86_64, linux-aarch64, darwin-x86_64, darwin-arm64, windows-x86_64, etc.",
        .type = FIELD_STRING,
        .defval = "auto",
    },
    {
        .key = "ANDROID_API",
        .prompt = "Android API level",
        .help = "NDK API level. Android 12 baseline is normally 31.",
        .type = FIELD_STRING,
        .defval = "31",
    },
    {
        .key = "TARGET_ARCH",
        .prompt = "Target architecture",
        .help = "RevA should normally use aarch64.",
        .type = FIELD_CHOICE,
        .defval = "aarch64",
        .choices = { arch_choices, ARRAY_SIZE(arch_choices) },
    },
    {
        .key = "TARGET_TRIPLE",
        .prompt = "NDK target triple",
        .help = "NDK compiler target triple prefix.",
        .type = FIELD_CHOICE,
        .defval = "aarch64-linux-android",
        .choices = { triple_choices, ARRAY_SIZE(triple_choices) },
    },
    {
        .key = "RECOVERY_LIBDIR",
        .prompt = "Recovery library directory",
        .help = "Usually lib64 for aarch64 recovery /system.",
        .type = FIELD_CHOICE,
        .defval = "lib64",
        .choices = { libdir_choices, ARRAY_SIZE(libdir_choices) },
    },
    {
        .key = "OUT_DIR",
        .prompt = "Foreign build output directory",
        .help = "Where foreign build objects and init.innit will be written.",
        .type = FIELD_PATH,
        .defval = "foreign/out/aarch64",
    },
    {
        .key = "BUILD_VARIANT",
        .prompt = "Foreign build variant",
        .help = "second_stage builds init.innit. policy_check is reserved for the host checker.",
        .type = FIELD_CHOICE,
        .defval = "second_stage",
        .choices = { variant_choices, ARRAY_SIZE(variant_choices) },
    },
    {
        .key = "ENABLE_SELINUX_SETUP",
        .prompt = "Support selinux_setup",
        .help = "Whether /system/bin/init selinux_setup mode is compiled/enabled.",
        .type = FIELD_CHOICE,
        .defval = "yes",
        .choices = { yes_no_choices, ARRAY_SIZE(yes_no_choices) },
    },
    {
        .key = "ENABLE_SUBCONTEXT",
        .prompt = "Support subcontext",
        .help = "auto means use subcontext if generated/proto sources are available.",
        .type = FIELD_CHOICE,
        .defval = "auto",
        .choices = { auto_yes_no_choices, ARRAY_SIZE(auto_yes_no_choices) },
    },
    {
        .key = "ENABLE_TINYXML2_DYNAMIC",
        .prompt = "Use dynamic libtinyxml2",
        .help = "yes links against recovery /system/lib64/libtinyxml2.so.",
        .type = FIELD_CHOICE,
        .defval = "yes",
        .choices = { yes_no_choices, ARRAY_SIZE(yes_no_choices) },
    },
    {
        .key = "JOBS",
        .prompt = "Parallel build jobs",
        .help = "Defaults to the number of online processors. Keep lower on memory-constrained systems.",
        .type = FIELD_STRING,
        .defval = "1",
    },
    {
        .key = "CXXFLAGS_EXTRA",
        .prompt = "Extra C++ flags",
        .help = "Optional extra compiler flags for the foreign build.",
        .type = FIELD_STRING,
        .defval = "",
    },
    {
        .key = "LDFLAGS_EXTRA",
        .prompt = "Extra linker flags",
        .help = "Optional extra linker flags for the foreign build.",
        .type = FIELD_STRING,
        .defval = "",
    },
};

enum {
    CP_BLUE_BG = 1,
    CP_DIALOG,
    CP_TITLE,
    CP_SELECTED,
    CP_HELP,
    CP_BUTTON,
    CP_BUTTON_SELECTED,
    CP_WARN,
    CP_OK,
    CP_FAIL,
};

enum main_focus {
    FOCUS_LIST = 0,
    FOCUS_BUTTONS = 1,
};

enum bottom_button {
    BTN_SELECT = 0,
    BTN_SAVE = 1,
    BTN_EXIT = 2,
    BTN_COUNT = 3,
};

static struct config_item *find_item(const char *key);

static void die_plain(const char *msg) {
    endwin();
    fprintf(stderr, "fatal: %s\n", msg);
    exit(1);
}

static void safe_strcpy(char *dst, size_t size, const char *src) {
    if (!dst || size == 0) return;

    if (!src) src = "";

    size_t n = strlen(src);
    if (n >= size) n = size - 1;

    memcpy(dst, src, n);
    dst[n] = '\0';
}

static bool has_suffix(const char *s, const char *suffix) {
    size_t slen = strlen(s);
    size_t tlen = strlen(suffix);

    return slen >= tlen && strcmp(s + slen - tlen, suffix) == 0;
}

static void append_suffix(char *out, size_t outsz, const char *base, const char *suffix) {
    if (!out || outsz == 0) return;
    if (!base) base = "";
    if (!suffix) suffix = "";

    size_t blen = strlen(base);
    size_t slen = strlen(suffix);
    size_t n = 0;

    if (blen + slen >= outsz) {
        out[0] = '\0';
        return;
    }

    memcpy(out + n, base, blen);
    n += blen;
    memcpy(out + n, suffix, slen);
    n += slen;
    out[n] = '\0';
}

static void join_path(char *out, size_t outsz, const char *left, const char *right) {
    if (!out || outsz == 0) return;
    if (!left) left = "";
    if (!right) right = "";

    size_t llen = strlen(left);
    size_t rlen = strlen(right);
    bool need_slash = llen > 0 && left[llen - 1] != '/';

    if (llen + (need_slash ? 1 : 0) + rlen >= outsz) {
        out[0] = '\0';
        return;
    }

    size_t n = 0;
    memcpy(out + n, left, llen);
    n += llen;

    if (need_slash) out[n++] = '/';

    memcpy(out + n, right, rlen);
    n += rlen;
    out[n] = '\0';
}

static bool directory_exists(const char *path) {
    if (!path || path[0] == '\0') return false;

    DIR *d = opendir(path);
    if (!d) return false;

    closedir(d);
    return true;
}

static void ndk_prebuilt_base(char *out, size_t outsz) {
    char tmp[PATH_MAX];

    join_path(tmp, sizeof(tmp), find_item("NDK_ROOT")->value, "toolchains/llvm/prebuilt");
    safe_strcpy(out, outsz, tmp);
}

static void preferred_host_tag(char *out, size_t outsz) {
    struct utsname u;

    if (uname(&u) != 0) {
        safe_strcpy(out, outsz, "unknown");
        return;
    }

    if (strcmp(u.sysname, "Linux") == 0) {
        if (strcmp(u.machine, "x86_64") == 0 || strcmp(u.machine, "amd64") == 0) {
            safe_strcpy(out, outsz, "linux-x86_64");
            return;
        }

        if (strcmp(u.machine, "aarch64") == 0 || strcmp(u.machine, "arm64") == 0) {
            safe_strcpy(out, outsz, "linux-aarch64");
            return;
        }

        safe_strcpy(out, outsz, "linux-x86_64");
        return;
    }

    if (strcmp(u.sysname, "Darwin") == 0) {
        if (strcmp(u.machine, "arm64") == 0 || strcmp(u.machine, "aarch64") == 0) {
            safe_strcpy(out, outsz, "darwin-arm64");
            return;
        }

        safe_strcpy(out, outsz, "darwin-x86_64");
        return;
    }

    if (strstr(u.sysname, "MINGW") || strstr(u.sysname, "MSYS") ||
        strstr(u.sysname, "CYGWIN") || strstr(u.sysname, "Windows")) {
        safe_strcpy(out, outsz, "windows-x86_64");
        return;
    }

    safe_strcpy(out, outsz, "unknown");
}

static bool ndk_host_tag_exists(const char *tag) {
    char base[PATH_MAX];
    char path[PATH_MAX];

    if (!tag || tag[0] == '\0') return false;

    ndk_prebuilt_base(base, sizeof(base));
    join_path(path, sizeof(path), base, tag);

    return directory_exists(path);
}

static void first_available_host_tag(char *out, size_t outsz) {
    char base[PATH_MAX];

    ndk_prebuilt_base(base, sizeof(base));

    DIR *d = opendir(base);
    if (!d) {
        safe_strcpy(out, outsz, "");
        return;
    }

    struct dirent *de;

    while ((de = readdir(d)) != NULL) {
        if (de->d_name[0] == '.') continue;

        char candidate[PATH_MAX];
        join_path(candidate, sizeof(candidate), base, de->d_name);

        if (directory_exists(candidate)) {
            safe_strcpy(out, outsz, de->d_name);
            closedir(d);
            return;
        }
    }

    closedir(d);
    safe_strcpy(out, outsz, "");
}

static void resolve_ndk_host_tag(char *out, size_t outsz) {
    struct config_item *item = find_item("NDK_HOST_TAG");
    const char *configured = item ? item->value : "auto";

    if (configured && configured[0] && strcmp(configured, "auto") != 0) {
        safe_strcpy(out, outsz, configured);
        return;
    }

    char preferred[128];
    preferred_host_tag(preferred, sizeof(preferred));

    if (ndk_host_tag_exists(preferred)) {
        safe_strcpy(out, outsz, preferred);
        return;
    }

    /*
     * Apple Silicon commonly still has darwin-x86_64 NDK prebuilts in older
     * NDKs. Accept that if darwin-arm64 is not present.
     */
    if (strcmp(preferred, "darwin-arm64") == 0 && ndk_host_tag_exists("darwin-x86_64")) {
        safe_strcpy(out, outsz, "darwin-x86_64");
        return;
    }

    /*
     * Some Linux ARM64 setups may use an x86_64 NDK through emulation or a
     * copied toolchain. Prefer explicit availability over assumption.
     */
    if (strcmp(preferred, "linux-aarch64") == 0 && ndk_host_tag_exists("linux-x86_64")) {
        safe_strcpy(out, outsz, "linux-x86_64");
        return;
    }

    first_available_host_tag(out, outsz);
}

static void derived_ndk_prebuilt(char *out, size_t outsz) {
    char base[PATH_MAX];
    char tag[128];

    ndk_prebuilt_base(base, sizeof(base));
    resolve_ndk_host_tag(tag, sizeof(tag));

    if (tag[0] == '\0') {
        safe_strcpy(out, outsz, "");
        return;
    }

    join_path(out, outsz, base, tag);
}


static void make_abs_path(char *out, size_t outsz, const char *path) {
    char cwd[PATH_MAX];
    char joined[PATH_MAX];
    char resolved[PATH_MAX];

    if (!path || path[0] == '\0') {
        safe_strcpy(out, outsz, "");
        return;
    }

    if (path[0] == '/') {
        if (realpath(path, resolved)) {
            safe_strcpy(out, outsz, resolved);
        } else {
            safe_strcpy(out, outsz, path);
        }
        return;
    }

    if (!getcwd(cwd, sizeof(cwd))) {
        safe_strcpy(out, outsz, path);
        return;
    }

    join_path(joined, sizeof(joined), cwd, path);

    if (realpath(joined, resolved)) {
        safe_strcpy(out, outsz, resolved);
    } else {
        safe_strcpy(out, outsz, joined);
    }
}

static const char *home_dir(void) {
    const char *h = getenv("HOME");
    return h ? h : "";
}

static void expand_default(char *out, size_t outsz, const char *in) {
    if (!in) {
        safe_strcpy(out, outsz, "");
        return;
    }

    if (strcmp(in, ".") == 0 || strcmp(in, "../..") == 0 || strcmp(in, "../../") == 0) {
        safe_strcpy(out, outsz, repo_root);
        return;
    }

    if (strncmp(in, "~/", 2) == 0) {
        char tmp[PATH_MAX];
        join_path(tmp, sizeof(tmp), home_dir(), in + 2);
        safe_strcpy(out, outsz, tmp);
        return;
    }

    if (strncmp(in, "foreign/", 8) == 0) {
        char tmp[PATH_MAX];
        join_path(tmp, sizeof(tmp), repo_root, in);
        safe_strcpy(out, outsz, tmp);
        return;
    }

    if (in[0] == '/' || strncmp(in, "../", 3) == 0 || strncmp(in, "./", 2) == 0) {
        make_abs_path(out, outsz, in);
        return;
    }

    safe_strcpy(out, outsz, in);
}

static void setup_runtime_defaults(void) {
    long n = sysconf(_SC_NPROCESSORS_ONLN);

    if (n < 1) n = 1;
    if (n > 9999) n = 9999;

    int ret = snprintf(jobs_default_value, sizeof(jobs_default_value), "%ld", n);
    if (ret < 0 || (size_t)ret >= sizeof(jobs_default_value)) {
        safe_strcpy(jobs_default_value, sizeof(jobs_default_value), "1");
    }

    for (size_t i = 0; i < ARRAY_SIZE(items); ++i) {
        if (strcmp(items[i].key, "JOBS") == 0) {
            items[i].defval = jobs_default_value;
            break;
        }
    }
}

static void init_defaults(void) {
    for (size_t i = 0; i < ARRAY_SIZE(items); ++i) {
        expand_default(items[i].value, sizeof(items[i].value), items[i].defval);
    }
}

static char *trim(char *s) {
    while (*s && isspace((unsigned char)*s)) s++;

    char *end = s + strlen(s);
    while (end > s && isspace((unsigned char)end[-1])) {
        *--end = '\0';
    }

    return s;
}

static bool contains_icase(const char *haystack, const char *needle_text) {
    if (!haystack || !needle_text) return false;
    if (*needle_text == '\0') return true;

    size_t nlen = strlen(needle_text);

    for (const char *h = haystack; *h; ++h) {
        size_t i = 0;

        while (i < nlen &&
               h[i] &&
               tolower((unsigned char)h[i]) == tolower((unsigned char)needle_text[i])) {
            ++i;
        }

        if (i == nlen) return true;
    }

    return false;
}

static void unquote_shellish(char *s) {
    size_t len = strlen(s);

    if (len >= 2 && ((s[0] == '\'' && s[len - 1] == '\'') ||
                     (s[0] == '"' && s[len - 1] == '"'))) {
        memmove(s, s + 1, len - 2);
        s[len - 2] = '\0';
    }
}

static struct config_item *find_item(const char *key) {
    for (size_t i = 0; i < ARRAY_SIZE(items); ++i) {
        if (strcmp(items[i].key, key) == 0) return &items[i];
    }
    return NULL;
}

static void load_config(void) {
    FILE *f = fopen(config_path, "r");
    if (!f) return;

    char line[VALUE_MAX * 2];

    while (fgets(line, sizeof(line), f)) {
        char *s = trim(line);

        if (*s == '#' || *s == '\0') continue;

        if (strncmp(s, "export ", 7) == 0) s += 7;

        char *eq = strchr(s, '=');
        if (!eq) continue;

        *eq = '\0';

        char *key = trim(s);
        char *val = trim(eq + 1);

        unquote_shellish(val);

        struct config_item *item = find_item(key);
        if (item) safe_strcpy(item->value, sizeof(item->value), val);
    }

    fclose(f);
}

static void quote_sh(FILE *f, const char *s) {
    fputc('\'', f);

    for (; s && *s; ++s) {
        if (*s == '\'') {
            fputs("'\\''", f);
        } else {
            fputc(*s, f);
        }
    }

    fputc('\'', f);
}

static void derived_recovery_lib(char *out, size_t outsz) {
    const char *system = find_item("RECOVERY_SYSTEM")->value;
    const char *libdir = find_item("RECOVERY_LIBDIR")->value;
    join_path(out, outsz, system, libdir);
}

static void derived_tool(char *out, size_t outsz, bool cxx) {
    const char *triple = find_item("TARGET_TRIPLE")->value;
    const char *api = find_item("ANDROID_API")->value;

    char prebuilt[PATH_MAX];
    char bin[PATH_MAX];
    char tool[256];

    derived_ndk_prebuilt(prebuilt, sizeof(prebuilt));

    if (prebuilt[0] == '\0') {
        safe_strcpy(out, outsz, "");
        return;
    }

    join_path(bin, sizeof(bin), prebuilt, "bin");

    int ret = snprintf(tool, sizeof(tool), "%s%s-clang%s", triple, api, cxx ? "++" : "");
    if (ret < 0 || (size_t)ret >= sizeof(tool)) {
        safe_strcpy(out, outsz, "");
        return;
    }

    join_path(out, outsz, bin, tool);
}

static void derived_init_output(char *out, size_t outsz) {
    const char *outdir = find_item("OUT_DIR")->value;
    join_path(out, outsz, outdir, "init.innit");
}

static void save_config(void) {
    char tmp[PATH_MAX];
    append_suffix(tmp, sizeof(tmp), config_path, ".tmp");

    FILE *f = fopen(tmp, "w");
    if (!f) die_plain("cannot open temporary config for writing");

    fprintf(f, "# Innit foreign build local configuration\n");
    fprintf(f, "# Generated by foreign/tools/innit-menuconfig\n");
    fprintf(f, "# This file is intentionally local-machine-specific.\n\n");
    fprintf(f, "export FOREIGN_CONFIG_VERSION=1\n");

    for (size_t i = 0; i < ARRAY_SIZE(items); ++i) {
        fprintf(f, "export %s=", items[i].key);
        quote_sh(f, items[i].value);
        fputc('\n', f);
    }

    char buf[PATH_MAX];

    derived_recovery_lib(buf, sizeof(buf));
    fprintf(f, "\nexport RECOVERY_LIB=");
    quote_sh(f, buf);
    fputc('\n', f);

    resolve_ndk_host_tag(buf, sizeof(buf));
    fprintf(f, "export NDK_HOST_TAG_RESOLVED=");
    quote_sh(f, buf);
    fputc('\n', f);

    derived_ndk_prebuilt(buf, sizeof(buf));
    fprintf(f, "export NDK_PREBUILT=");
    quote_sh(f, buf);
    fputc('\n', f);

    derived_tool(buf, sizeof(buf), false);
    fprintf(f, "export NDK_CC=");
    quote_sh(f, buf);
    fputc('\n', f);

    derived_tool(buf, sizeof(buf), true);
    fprintf(f, "export NDK_CXX=");
    quote_sh(f, buf);
    fputc('\n', f);

    derived_init_output(buf, sizeof(buf));
    fprintf(f, "export INIT_OUTPUT=");
    quote_sh(f, buf);
    fputc('\n', f);

    fclose(f);

    if (rename(tmp, config_path) != 0) {
        die_plain("cannot replace config file");
    }
}

static bool path_exists(const char *p) {
    return p && access(p, F_OK) == 0;
}

static void setup_colors(void) {
    start_color();
    use_default_colors();

    init_pair(CP_BLUE_BG, COLOR_WHITE, COLOR_BLUE);
    init_pair(CP_DIALOG, COLOR_BLACK, COLOR_WHITE);
    init_pair(CP_TITLE, COLOR_YELLOW, COLOR_BLUE);
    init_pair(CP_SELECTED, COLOR_YELLOW, COLOR_BLUE);
    init_pair(CP_HELP, COLOR_CYAN, COLOR_WHITE);
    init_pair(CP_BUTTON, COLOR_BLUE, COLOR_WHITE);
    init_pair(CP_BUTTON_SELECTED, COLOR_WHITE, COLOR_BLUE);
    init_pair(CP_WARN, COLOR_YELLOW, COLOR_BLUE);
    init_pair(CP_OK, COLOR_GREEN, COLOR_BLUE);
    init_pair(CP_FAIL, COLOR_RED, COLOR_BLUE);
}

static void draw_boxed_window(int y, int x, int h, int w, const char *title) {
    attron(COLOR_PAIR(CP_DIALOG));
    for (int r = 0; r < h; ++r) {
        mvhline(y + r, x, ' ', w);
    }

    mvaddch(y, x, ACS_ULCORNER);
    mvhline(y, x + 1, ACS_HLINE, w - 2);
    mvaddch(y, x + w - 1, ACS_URCORNER);

    for (int r = 1; r < h - 1; ++r) {
        mvaddch(y + r, x, ACS_VLINE);
        mvaddch(y + r, x + w - 1, ACS_VLINE);
    }

    mvaddch(y + h - 1, x, ACS_LLCORNER);
    mvhline(y + h - 1, x + 1, ACS_HLINE, w - 2);
    mvaddch(y + h - 1, x + w - 1, ACS_LRCORNER);

    if (title) {
        attron(A_BOLD);
        mvprintw(y, x + 3, " %s ", title);
        attroff(A_BOLD);
    }

    attroff(COLOR_PAIR(CP_DIALOG));
}

static void shorten(const char *in, char *out, size_t outsz, int maxw) {
    if (!out || outsz == 0) return;
    if (!in) in = "";

    if (maxw < 1) {
        out[0] = '\0';
        return;
    }

    if ((size_t)maxw >= outsz) maxw = (int)outsz - 1;

    size_t len = strlen(in);
    if ((int)len <= maxw) {
        safe_strcpy(out, outsz, in);
        return;
    }

    if (maxw < 4) {
        size_t n = (size_t)maxw;
        memcpy(out, in, n);
        out[n] = '\0';
        return;
    }

    const char *tail = in + len - (size_t)(maxw - 3);
    out[0] = '.';
    out[1] = '.';
    out[2] = '.';
    safe_strcpy(out + 3, outsz - 3, tail);
}

static void draw_button(int y, int x, const char *text, bool selected) {
    attron(COLOR_PAIR(selected ? CP_BUTTON_SELECTED : CP_BUTTON));
    if (selected) attron(A_BOLD);
    mvprintw(y, x, "<%s>", text);
    if (selected) attroff(A_BOLD);
    attroff(COLOR_PAIR(selected ? CP_BUTTON_SELECTED : CP_BUTTON));
}

static void print_clipped(int y, int x, int maxw, const char *s) {
    if (maxw <= 0) return;

    mvhline(y, x, ' ', maxw);
    mvaddnstr(y, x, s ? s : "", maxw);
}

static void print_shortened(int y, int x, int maxw, const char *s) {
    char buf[VALUE_MAX];

    if (maxw <= 0) return;

    shorten(s ? s : "", buf, sizeof(buf), maxw);
    print_clipped(y, x, maxw, buf);
}

static void draw_footer_hints(int y, int x, int w) {
    attron(COLOR_PAIR(CP_DIALOG));

    if (w >= 92) {
        print_clipped(y + 0, x, w,
                      "Arrows: Navigate  Enter/Space: Activate  Tab: Buttons  /: Search  ?: Help");
        print_clipped(y + 1, x, w,
                      "S: Save  Q/Esc: Exit");
    } else if (w >= 68) {
        print_clipped(y + 0, x, w,
                      "Arrows: Move  Enter: Activate  Tab: Buttons");
        print_clipped(y + 1, x, w,
                      "S: Save  /: Search  ?: Help  Q/Esc: Exit");
    } else {
        print_clipped(y + 0, x, w,
                      "Enter: Activate  Tab: Buttons");
        print_clipped(y + 1, x, w,
                      "S:Save /:Search ?:Help Q/Esc:Exit");
    }

    attroff(COLOR_PAIR(CP_DIALOG));
}

static void draw_too_small(void) {
    int rows, cols;
    getmaxyx(stdscr, rows, cols);

    erase();
    bkgd(COLOR_PAIR(CP_BLUE_BG));

    attron(COLOR_PAIR(CP_TITLE) | A_BOLD);
    mvprintw(rows > 3 ? rows / 2 - 1 : 0, 2, "Terminal too small.");
    attroff(COLOR_PAIR(CP_TITLE) | A_BOLD);

    if (rows > 2) {
        attron(COLOR_PAIR(CP_BLUE_BG));
        mvprintw(rows / 2, 2, "Please resize to at least 70x18.");
        if (rows / 2 + 1 < rows) {
            mvprintw(rows / 2 + 1, 2, "Current size: %dx%d", cols, rows);
        }
        attroff(COLOR_PAIR(CP_BLUE_BG));
    }

    refresh();
}

static void draw_main(int selected, int top, enum main_focus focus, enum bottom_button button) {
    erase();
    bkgd(COLOR_PAIR(CP_BLUE_BG));

    int rows, cols;
    getmaxyx(stdscr, rows, cols);

    if (cols < 70 || rows < 18) {
        draw_too_small();
        return;
    }

    const char *title = "Innit Foreign Build Configuration";
    int title_x = (cols - (int)strlen(title)) / 2;
    if (title_x < 0) title_x = 0;

    attron(COLOR_PAIR(CP_TITLE) | A_BOLD);
    mvaddnstr(1, title_x, title, cols - title_x);
    attroff(COLOR_PAIR(CP_TITLE) | A_BOLD);

    int win_h = rows - 6;
    int win_w = cols - 8;
    int wy = 3;
    int wx = (cols - win_w) / 2;

    draw_boxed_window(wy, wx, win_h, win_w, " Innit foreign menuconfig ");

    int inner_x = wx + 3;
    int inner_w = win_w - 6;

    int opt_x = inner_x;
    int val_x = wx + win_w / 2 + 1;
    int opt_w = val_x - opt_x - 2;
    int val_w = wx + win_w - 3 - val_x;

    if (opt_w < 10) opt_w = 10;
    if (val_w < 10) val_w = 10;

    int header_y = wy + 1;
    int rule_y = wy + 2;
    int list_y = wy + 3;
    int help_rule_y = wy + win_h - 7;
    int help_y = wy + win_h - 6;
    int footer_y = wy + win_h - 4;
    int button_y = wy + win_h - 2;

    int list_h = help_rule_y - list_y;
    if (list_h < 1) list_h = 1;

    if (selected < top) top = selected;
    if (selected >= top + list_h) top = selected - list_h + 1;
    if (top < 0) top = 0;

    attron(COLOR_PAIR(CP_DIALOG));
    print_clipped(header_y, opt_x, opt_w, "Option");
    print_clipped(header_y, val_x, val_w, "Value");
    mvhline(rule_y, wx + 2, ACS_HLINE, win_w - 4);
    attroff(COLOR_PAIR(CP_DIALOG));

    for (int row = 0; row < list_h; ++row) {
        int idx = top + row;
        if (idx >= (int)ARRAY_SIZE(items)) break;

        int y = list_y + row;
        bool selected_row = idx == selected && focus == FOCUS_LIST;

        attron(COLOR_PAIR(selected_row ? CP_SELECTED : CP_DIALOG));
        if (selected_row) attron(A_BOLD);

        mvhline(y, wx + 2, ' ', win_w - 4);
        print_shortened(y, opt_x, opt_w, items[idx].prompt);
        print_shortened(y, val_x, val_w, items[idx].value);

        if (selected_row) attroff(A_BOLD);
        attroff(COLOR_PAIR(selected_row ? CP_SELECTED : CP_DIALOG));
    }

    attron(COLOR_PAIR(CP_HELP));
    mvhline(help_rule_y, wx + 2, ACS_HLINE, win_w - 4);
    print_clipped(help_y, inner_x, inner_w, items[selected].help);
    attroff(COLOR_PAIR(CP_HELP));

    draw_footer_hints(footer_y, inner_x, inner_w);

    int bx = wx + (win_w - 30) / 2;
    if (bx < inner_x) bx = inner_x;

    draw_button(button_y, bx + 0, "Select", focus == FOCUS_BUTTONS && button == BTN_SELECT);
    draw_button(button_y, bx + 10, "Save", focus == FOCUS_BUTTONS && button == BTN_SAVE);
    draw_button(button_y, bx + 18, "Exit", focus == FOCUS_BUTTONS && button == BTN_EXIT);

    refresh();
}

static int choice_index(const struct config_item *item) {
    for (size_t i = 0; i < item->choices.count; ++i) {
        if (strcmp(item->value, item->choices.items[i]) == 0) return (int)i;
    }
    return 0;
}

static void cycle_choice(struct config_item *item, int delta) {
    if (item->type != FIELD_CHOICE || item->choices.count == 0) return;

    int idx = choice_index(item);
    idx += delta;

    if (idx < 0) idx = (int)item->choices.count - 1;
    if (idx >= (int)item->choices.count) idx = 0;

    safe_strcpy(item->value, sizeof(item->value), item->choices.items[idx]);
}

static bool dialog_text_input(int y, int x, int w, const char *initial,
                              char *out, size_t outsz) {
    char buf[VALUE_MAX];
    size_t len = 0;
    int cursor = 0;

    safe_strcpy(buf, sizeof(buf), initial ? initial : "");
    len = strlen(buf);
    cursor = (int)len;

    keypad(stdscr, TRUE);
    curs_set(1);

    for (;;) {
        int field_w = w - 8;
        if (field_w < 8) field_w = 8;

        attron(COLOR_PAIR(CP_DIALOG));
        mvhline(y, x, ' ', field_w);

        int start = 0;
        if (cursor >= field_w) start = cursor - field_w + 1;

        char visible[VALUE_MAX];
        safe_strcpy(visible, sizeof(visible), buf + start);

        if ((int)strlen(visible) > field_w) {
            visible[field_w] = '\0';
        }

        mvprintw(y, x, "%s", visible);
        attroff(COLOR_PAIR(CP_DIALOG));

        move(y, x + cursor - start);
        refresh();

        int ch = getch();

        switch (ch) {
        case 27:
            curs_set(0);
            return false;

        case '\n':
        case '\r':
            safe_strcpy(out, outsz, buf);
            curs_set(0);
            return true;

        case KEY_LEFT:
            if (cursor > 0) cursor--;
            break;

        case KEY_RIGHT:
            if (cursor < (int)len) cursor++;
            break;

        case KEY_HOME:
            cursor = 0;
            break;

        case KEY_END:
            cursor = (int)len;
            break;

        case KEY_BACKSPACE:
        case 127:
        case 8:
            if (cursor > 0 && len > 0) {
                memmove(buf + cursor - 1, buf + cursor, len - (size_t)cursor + 1);
                cursor--;
                len--;
            }
            break;

        case KEY_DC:
            if (cursor < (int)len) {
                memmove(buf + cursor, buf + cursor + 1, len - (size_t)cursor);
                len--;
            }
            break;

        default:
            if (isprint(ch) && len + 1 < sizeof(buf)) {
                memmove(buf + cursor + 1, buf + cursor, len - (size_t)cursor + 1);
                buf[cursor] = (char)ch;
                cursor++;
                len++;
            }
            break;
        }
    }
}

static void edit_string(struct config_item *item) {
    int rows, cols;
    getmaxyx(stdscr, rows, cols);

    int w = cols - 12;
    if (w < 60) w = cols - 2;

    int h = 10;
    int y = (rows - h) / 2;
    int x = (cols - w) / 2;

    char buf[VALUE_MAX];

    draw_boxed_window(y, x, h, w, " Edit value ");

    attron(COLOR_PAIR(CP_DIALOG));
    mvprintw(y + 2, x + 3, "%s", item->prompt);
    mvprintw(y + 3, x + 3, "%s", item->help);
    mvprintw(y + 5, x + 3, "> ");
    mvprintw(y + 7, x + 3, "Enter: Accept    Esc: Cancel");
    attroff(COLOR_PAIR(CP_DIALOG));

    bool accepted = dialog_text_input(y + 5, x + 5, w, item->value, buf, sizeof(buf));

    if (accepted) {
        safe_strcpy(item->value, sizeof(item->value), buf);
    }

    curs_set(0);
}


static void edit_item(struct config_item *item) {
    if (item->type == FIELD_CHOICE) {
        cycle_choice(item, +1);
    } else {
        edit_string(item);
    }
}

static void show_help(const struct config_item *item) {
    int rows, cols;
    getmaxyx(stdscr, rows, cols);

    int w = cols - 10;
    int h = 12;
    if (w < 60) w = cols - 2;
    if (h > rows - 2) h = rows - 2;

    int y = (rows - h) / 2;
    int x = (cols - w) / 2;

    draw_boxed_window(y, x, h, w, " Help ");

    attron(COLOR_PAIR(CP_DIALOG));
    mvprintw(y + 2, x + 3, "%s", item->prompt);
    mvprintw(y + 4, x + 3, "%s", item->help);
    mvprintw(y + h - 3, x + 3, "Symbol: %s", item->key);
    mvprintw(y + h - 2, x + 3, "Press any key to return.");
    attroff(COLOR_PAIR(CP_DIALOG));

    getch();
}

static void message_box(const char *title, const char *msg) {
    int rows, cols;
    getmaxyx(stdscr, rows, cols);

    int w = cols - 14;
    if (w < 50) w = cols - 2;
    int h = 7;
    int y = (rows - h) / 2;
    int x = (cols - w) / 2;

    draw_boxed_window(y, x, h, w, title);

    attron(COLOR_PAIR(CP_DIALOG));
    mvprintw(y + 3, x + 3, "%s", msg);
    mvprintw(y + h - 2, x + 3, "Press any key, or Esc, to return.");
    attroff(COLOR_PAIR(CP_DIALOG));

    getch();
}

static void audit_screen(void) {
    erase();
    bkgd(COLOR_PAIR(CP_BLUE_BG));

    int y = 1;

    attron(COLOR_PAIR(CP_TITLE) | A_BOLD);
    mvprintw(y++, 2, "Innit foreign build audit");
    attroff(COLOR_PAIR(CP_TITLE) | A_BOLD);
    y++;

#define AUDIT(cond, label) \
    do { \
        attron(COLOR_PAIR((cond) ? CP_OK : CP_FAIL) | A_BOLD); \
        mvprintw(y, 4, "%s", (cond) ? "OK  " : "FAIL"); \
        attroff(COLOR_PAIR((cond) ? CP_OK : CP_FAIL) | A_BOLD); \
        attron(COLOR_PAIR(CP_BLUE_BG)); \
        mvprintw(y++, 10, "%s", (label)); \
        attroff(COLOR_PAIR(CP_BLUE_BG)); \
    } while (0)

    char path[PATH_MAX];

    join_path(path, sizeof(path), find_item("INNIT_ROOT")->value, "init");
    AUDIT(path_exists(path), "Innit init source directory");

    join_path(path, sizeof(path), find_item("AOSP_QUARRY")->value, "system/core");
    AUDIT(path_exists(path), "AOSP quarry system/core");

    join_path(path, sizeof(path), find_item("AOSP_QUARRY")->value, "external/tinyxml2");
    AUDIT(path_exists(path), "AOSP quarry external/tinyxml2");

    AUDIT(path_exists(find_item("RECOVERY_SYSTEM")->value), "Recovery /system root");

    derived_recovery_lib(path, sizeof(path));
    AUDIT(path_exists(path), "Recovery library directory");

    char host_tag[128];
    char prebuilt_dir[PATH_MAX];
    char tool[PATH_MAX];

    resolve_ndk_host_tag(host_tag, sizeof(host_tag));
    derived_ndk_prebuilt(prebuilt_dir, sizeof(prebuilt_dir));
    derived_tool(tool, sizeof(tool), true);

    AUDIT(host_tag[0] != '\0', "Resolved NDK host prebuilt tag");
    AUDIT(directory_exists(prebuilt_dir), "NDK LLVM prebuilt host directory");
    AUDIT(access(tool, X_OK) == 0, "NDK clang++");

    const char *libs[] = {
        "libbase.so",
        "liblog.so",
        "libcutils.so",
        "libc++.so",
        "libc.so",
        "libm.so",
        "libdl.so",
        "libtinyxml2.so",
    };

    y++;
    attron(COLOR_PAIR(CP_TITLE) | A_BOLD);
    mvprintw(y++, 2, "Recovery ABI");
    attroff(COLOR_PAIR(CP_TITLE) | A_BOLD);

    char rec_lib[PATH_MAX];
    derived_recovery_lib(rec_lib, sizeof(rec_lib));

    for (size_t i = 0; i < ARRAY_SIZE(libs); ++i) {
        join_path(path, sizeof(path), rec_lib, libs[i]);
        AUDIT(path_exists(path), libs[i]);
    }

    y++;
    attron(COLOR_PAIR(CP_BLUE_BG));
    mvprintw(y++, 2, "Config: %s", config_path);
    mvprintw(y++, 2, "NDK host tag: %s", host_tag);
    mvprintw(y++, 2, "NDK prebuilt: %s", prebuilt_dir);
    mvprintw(y++, 2, "Press any key to return.");
    attroff(COLOR_PAIR(CP_BLUE_BG));

#undef AUDIT

    refresh();
    getch();
}

static void search_prompt(int *selected, int *top) {
    int rows, cols;
    getmaxyx(stdscr, rows, cols);

    int w = cols - 12;
    if (w < 60) w = cols - 2;

    int h = 8;
    int y = (rows - h) / 2;
    int x = (cols - w) / 2;

    char query[128] = {0};

    draw_boxed_window(y, x, h, w, " Search ");

    attron(COLOR_PAIR(CP_DIALOG));
    mvprintw(y + 2, x + 3, "Search string:");
    mvprintw(y + 5, x + 3, "Enter: Search    Esc: Cancel");
    mvprintw(y + 3, x + 3, "> ");
    attroff(COLOR_PAIR(CP_DIALOG));

    bool accepted = dialog_text_input(y + 3, x + 5, w, "", query, sizeof(query));

    if (!accepted || query[0] == '\0') return;

    for (size_t i = 0; i < ARRAY_SIZE(items); ++i) {
        if (contains_icase(items[i].key, query) ||
            contains_icase(items[i].prompt, query) ||
            contains_icase(items[i].help, query)) {
            *selected = (int)i;
            *top = *selected > 2 ? *selected - 2 : 0;
            return;
        }
    }

    message_box(" Search ", "No matching symbol found.");
}


static bool confirm_exit(void) {
    enum bottom_button button = BTN_SELECT; /* Reuse: Select=Yes, Save=No, Exit=Cancel */

    for (;;) {
        int rows, cols;
        getmaxyx(stdscr, rows, cols);

        int w = 52;
        int h = 8;
        int y = (rows - h) / 2;
        int x = (cols - w) / 2;

        draw_boxed_window(y, x, h, w, " Exit ");

        attron(COLOR_PAIR(CP_DIALOG));
        mvprintw(y + 2, x + 3, "Save configuration before exiting?");
        mvprintw(y + 3, x + 3, "Left/Right: Move  Enter: Choose  Esc: Cancel");
        attroff(COLOR_PAIR(CP_DIALOG));

        draw_button(y + 5, x + 8, "Yes", button == BTN_SELECT);
        draw_button(y + 5, x + 19, "No", button == BTN_SAVE);
        draw_button(y + 5, x + 28, "Cancel", button == BTN_EXIT);

        int ch = getch();

        switch (ch) {
        case KEY_LEFT:
        case 'h':
            button = (enum bottom_button)((button + BTN_COUNT - 1) % BTN_COUNT);
            break;

        case KEY_RIGHT:
        case 'l':
        case '\t':
            button = (enum bottom_button)((button + 1) % BTN_COUNT);
            break;

        case '\n':
        case '\r':
        case ' ':
            if (button == BTN_SELECT) {
                save_config();
                return true;
            }
            if (button == BTN_SAVE) {
                return true;
            }
            return false;

        case 'y':
        case 'Y':
            save_config();
            return true;

        case 'n':
        case 'N':
            return true;

        case 27:
        case 'q':
        case 'Q':
            return false;

        default:
            break;
        }
    }
}


static void reset_defaults_confirm(void) {
    int rows, cols;
    getmaxyx(stdscr, rows, cols);

    int w = 52;
    int h = 7;
    int y = (rows - h) / 2;
    int x = (cols - w) / 2;

    draw_boxed_window(y, x, h, w, " Load defaults ");

    attron(COLOR_PAIR(CP_DIALOG));
    mvprintw(y + 2, x + 3, "Reset all values to defaults? [y/N]");
    attroff(COLOR_PAIR(CP_DIALOG));

    int ch = getch();
    if (ch == 'y' || ch == 'Y') {
        init_defaults();
    }
}

static void compute_paths(void) {
    char cwd[PATH_MAX];

    if (!getcwd(cwd, sizeof(cwd))) {
        fprintf(stderr, "getcwd failed: %s\n", strerror(errno));
        exit(1);
    }

    safe_strcpy(repo_root, sizeof(repo_root), cwd);

    if (has_suffix(repo_root, "/foreign/tools")) {
        repo_root[strlen(repo_root) - strlen("/foreign/tools")] = '\0';
    } else if (has_suffix(repo_root, "/foreign")) {
        repo_root[strlen(repo_root) - strlen("/foreign")] = '\0';
    }

    join_path(config_path, sizeof(config_path), repo_root, "foreign/config/local.env");

    if (config_path[0] == '\0') {
        fprintf(stderr, "computed config path is too long\n");
        exit(1);
    }
}

int main(void) {
    compute_paths();
    setup_runtime_defaults();
    init_defaults();
    load_config();

    initscr();
    cbreak();
    noecho();
    keypad(stdscr, TRUE);
#ifdef NCURSES_VERSION
    set_escdelay(25);
#endif
    curs_set(0);

    if (!has_colors()) {
        endwin();
        fprintf(stderr, "terminal does not support colors\n");
        return 1;
    }

    setup_colors();

    int selected = 0;
    int top = 0;
    enum main_focus focus = FOCUS_LIST;
    enum bottom_button button = BTN_SELECT;

    for (;;) {
        int rows = getmaxy(stdscr);

        int list_h = rows - 14;
        if (list_h < 5) list_h = 5;

        if (selected < top) top = selected;
        if (selected >= top + list_h) top = selected - list_h + 1;

        draw_main(selected, top, focus, button);

        int ch = getch();

        switch (ch) {
        case KEY_UP:
        case 'k':
            if (focus == FOCUS_BUTTONS) {
                focus = FOCUS_LIST;
            } else if (selected > 0) {
                selected--;
            }
            break;

        case KEY_DOWN:
        case 'j':
            if (focus == FOCUS_BUTTONS) {
                /* Stay on buttons. */
            } else if (selected < (int)ARRAY_SIZE(items) - 1) {
                selected++;
            } else {
                focus = FOCUS_BUTTONS;
                button = BTN_SELECT;
            }
            break;

        case KEY_NPAGE:
            focus = FOCUS_LIST;
            selected += list_h;
            if (selected >= (int)ARRAY_SIZE(items)) selected = (int)ARRAY_SIZE(items) - 1;
            break;

        case KEY_PPAGE:
            focus = FOCUS_LIST;
            selected -= list_h;
            if (selected < 0) selected = 0;
            break;

        case KEY_HOME:
            focus = FOCUS_LIST;
            selected = 0;
            break;

        case KEY_END:
            focus = FOCUS_LIST;
            selected = (int)ARRAY_SIZE(items) - 1;
            break;

        case KEY_LEFT:
        case 'h':
            if (focus == FOCUS_BUTTONS) {
                button = (enum bottom_button)((button + BTN_COUNT - 1) % BTN_COUNT);
            }
            break;

        case KEY_RIGHT:
        case 'l':
            if (focus == FOCUS_BUTTONS) {
                button = (enum bottom_button)((button + 1) % BTN_COUNT);
            } else {
                focus = FOCUS_BUTTONS;
                button = BTN_SELECT;
            }
            break;

        case '\t':
            if (focus == FOCUS_LIST) {
                focus = FOCUS_BUTTONS;
                button = BTN_SELECT;
            } else {
                focus = FOCUS_LIST;
            }
            break;

        case '\n':
        case '\r':
        case ' ':
            if (focus == FOCUS_BUTTONS) {
                if (button == BTN_SELECT) {
                    focus = FOCUS_LIST;
                    edit_item(&items[selected]);
                } else if (button == BTN_SAVE) {
                    save_config();
                    message_box(" Save ", "Configuration written to foreign/config/local.env");
                } else if (button == BTN_EXIT) {
                    if (confirm_exit()) {
                        endwin();
                        return 0;
                    }
                }
            } else {
                edit_item(&items[selected]);
            }
            break;

        case '?':
            show_help(&items[selected]);
            break;

        case '/':
            focus = FOCUS_LIST;
            search_prompt(&selected, &top);
            break;

        case 'a':
        case 'A':
            audit_screen();
            break;

        case 'd':
        case 'D':
            reset_defaults_confirm();
            break;

        case 's':
        case 'S':
            save_config();
            message_box(" Save ", "Configuration written to foreign/config/local.env");
            break;

        case 27:
        case 'q':
        case 'Q':
            if (confirm_exit()) {
                endwin();
                return 0;
            }
            break;

        default:
            break;
        }
    }
}
