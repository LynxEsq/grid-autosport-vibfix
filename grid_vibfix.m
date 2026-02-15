// grid_vibfix.dylib — enables Xbox controller vibration in GRID Autosport on macOS
//
// Listens on UDP port 20777 for EGO engine telemetry (Codemasters format),
// parses car physics data, generates vibration effects (impact, surface, slip,
// engine, braking, cornering), and sends rumble to Xbox controller via BT HID.
//
// Settings are loaded from config.txt (same directory as the dylib).
// Must be compiled as x86_64 (game runs under Rosetta 2).

#import <Foundation/Foundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <pthread.h>
#include <math.h>
#include <sys/time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <mach-o/dyld.h>
#include <signal.h>

#define VERSION "3.2"

// ============ Xbox Controller IDs ============

#define XBOX_VENDOR_ID 0x045E

static const uint16_t XBOX_PRODUCT_IDS[] = {
    0x0B22,  // Xbox Elite Series 2 (BLE)
    0x0B05,  // Xbox Elite Series 2
    0x0B20,  // Xbox One S (Bluetooth)
    0x0B13,  // Xbox Series X|S (Bluetooth)
    0x02FD,  // Xbox One S (Bluetooth, older fw)
    0x0B21,  // Xbox Adaptive Controller (BT)
    0
};

static int is_xbox_controller(uint16_t vid, uint16_t pid) {
    if (vid != XBOX_VENDOR_ID) return 0;
    for (int i = 0; XBOX_PRODUCT_IDS[i]; i++) {
        if (pid == XBOX_PRODUCT_IDS[i]) return 1;
    }
    return 0;
}

// ============ Logging ============

static FILE *g_logfile = NULL;
static pthread_mutex_t g_logmutex = PTHREAD_MUTEX_INITIALIZER;
static char g_install_dir[1024] = "/tmp/grid_vibfix";

static void find_install_dir(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "grid_vibfix.dylib")) {
            strncpy(g_install_dir, name, sizeof(g_install_dir) - 1);
            char *last_slash = strrchr(g_install_dir, '/');
            if (last_slash) *last_slash = '\0';
            break;
        }
    }
}

static void viblog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void viblog(const char *fmt, ...) {
    pthread_mutex_lock(&g_logmutex);
    if (!g_logfile) {
        char path[1100];
        snprintf(path, sizeof(path), "%s/grid_vibfix.log", g_install_dir);
        g_logfile = fopen(path, "w");
        if (g_logfile) setbuf(g_logfile, NULL);
    }
    if (g_logfile) {
        struct timeval tv;
        gettimeofday(&tv, NULL);
        struct tm tm;
        localtime_r(&tv.tv_sec, &tm);
        fprintf(g_logfile, "[%02d:%02d:%02d.%03d] ",
                tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000));
        va_list ap;
        va_start(ap, fmt);
        vfprintf(g_logfile, fmt, ap);
        fprintf(g_logfile, "\n");
        va_end(ap);
    }
    pthread_mutex_unlock(&g_logmutex);
}

// ============ Utility ============

static float clampf(float val, float mn, float mx) {
    if (val < mn) return mn;
    if (val > mx) return mx;
    return val;
}

// ============ Configuration ============

typedef struct {
    // Strength multipliers (0.0-2.0, loaded from 0-200%)
    float overall;
    float impact;
    float surface;
    float cornering;
    float slip;
    float engine;
    float brake;

    // Impact hold decay (0.0-0.99)
    float impact_hold;

    // General
    int   test_on_start;
    int   log_telemetry;
    float dead_zone;

    // Advanced thresholds
    float impact_delta_threshold;
    float impact_abs_threshold;
    float surface_threshold;
    float engine_rpm_threshold;
    float slip_threshold;
} VibConfig;

static VibConfig g_cfg = {
    .overall              = 1.0f,
    .impact               = 1.0f,
    .surface              = 1.0f,
    .cornering            = 1.0f,
    .slip                 = 1.0f,
    .engine               = 1.0f,
    .brake                = 1.0f,
    .impact_hold          = 0.85f,
    .test_on_start        = 1,
    .log_telemetry        = 0,
    .dead_zone            = 3.0f,
    .impact_delta_threshold = 0.7f,
    .impact_abs_threshold   = 5.0f,
    .surface_threshold      = 60.0f,
    .engine_rpm_threshold   = 4000.0f,
    .slip_threshold         = 3.0f,
};

static void load_config(void) {
    char path[1100];
    snprintf(path, sizeof(path), "%s/config.txt", g_install_dir);

    FILE *f = fopen(path, "r");
    if (!f) {
        viblog("Config: %s not found, using defaults", path);
        return;
    }
    viblog("Config: loading %s", path);

    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\0') continue;

        char key[64] = {0};
        char val[64] = {0};
        if (sscanf(p, "%63[^= ] = %63s", key, val) != 2) continue;

        int is_true = (strcmp(val, "true") == 0 || strcmp(val, "1") == 0 ||
                       strcmp(val, "yes") == 0);
        int is_false = (strcmp(val, "false") == 0 || strcmp(val, "0") == 0 ||
                        strcmp(val, "no") == 0);
        float pct = clampf(atof(val) / 100.0f, 0.0f, 2.0f);  // 0-200%
        float raw = atof(val);

        // Strength multipliers (percentage 0-200)
        if      (strcmp(key, "overall_strength") == 0)   g_cfg.overall = pct;
        else if (strcmp(key, "impact_strength") == 0)    g_cfg.impact = pct;
        else if (strcmp(key, "surface_strength") == 0)   g_cfg.surface = pct;
        else if (strcmp(key, "cornering_strength") == 0) g_cfg.cornering = pct;
        else if (strcmp(key, "slip_strength") == 0)      g_cfg.slip = pct;
        else if (strcmp(key, "engine_strength") == 0)    g_cfg.engine = pct;
        else if (strcmp(key, "brake_strength") == 0)     g_cfg.brake = pct;

        // Impact hold (0-99 → 0.0-0.99)
        else if (strcmp(key, "impact_hold") == 0)
            g_cfg.impact_hold = clampf(raw / 100.0f, 0.0f, 0.99f);

        // Booleans
        else if (strcmp(key, "test_on_start") == 0)
            g_cfg.test_on_start = is_true ? 1 : (is_false ? 0 : (int)raw);
        else if (strcmp(key, "log_telemetry") == 0)
            g_cfg.log_telemetry = is_true ? 1 : (is_false ? 0 : (int)raw);

        // Dead zone (raw value 0-10)
        else if (strcmp(key, "dead_zone") == 0)
            g_cfg.dead_zone = clampf(raw, 0.0f, 10.0f);

        // Advanced thresholds (raw values)
        else if (strcmp(key, "impact_delta_threshold") == 0)
            g_cfg.impact_delta_threshold = clampf(raw, 0.1f, 5.0f);
        else if (strcmp(key, "impact_abs_threshold") == 0)
            g_cfg.impact_abs_threshold = clampf(raw, 1.0f, 20.0f);
        else if (strcmp(key, "surface_threshold") == 0)
            g_cfg.surface_threshold = clampf(raw, 10.0f, 200.0f);
        else if (strcmp(key, "engine_rpm_threshold") == 0)
            g_cfg.engine_rpm_threshold = clampf(raw, 1000.0f, 8000.0f);
        else if (strcmp(key, "slip_threshold") == 0)
            g_cfg.slip_threshold = clampf(raw, 0.5f, 10.0f);
        else {
            viblog("Config: unknown key '%s'", key);
        }
    }
    fclose(f);

    viblog("Config: overall=%.0f%% imp=%.0f%% surf=%.0f%% cor=%.0f%% slip=%.0f%% eng=%.0f%% brk=%.0f%%",
           g_cfg.overall * 100, g_cfg.impact * 100, g_cfg.surface * 100,
           g_cfg.cornering * 100, g_cfg.slip * 100, g_cfg.engine * 100, g_cfg.brake * 100);
    viblog("Config: hold=%.2f test=%d log=%d dz=%.0f | thresholds: dGf=%.1f absGf=%.1f suspV=%.0f rpm=%.0f slip=%.1f",
           g_cfg.impact_hold, g_cfg.test_on_start, g_cfg.log_telemetry, g_cfg.dead_zone,
           g_cfg.impact_delta_threshold, g_cfg.impact_abs_threshold,
           g_cfg.surface_threshold, g_cfg.engine_rpm_threshold, g_cfg.slip_threshold);
}

// ============ Xbox Controller State ============

static IOHIDDeviceRef g_xbox_device = NULL;
static uint16_t g_xbox_pid = 0;
static int g_test_sent = 0;

// ============ HID Rumble ============

static IOReturn send_xbox_rumble(IOHIDDeviceRef device,
                                  uint8_t left_motor, uint8_t right_motor,
                                  uint8_t left_trigger, uint8_t right_trigger) {
    if (!device) return kIOReturnBadArgument;

    uint8_t report[9] = {
        0x03, 0x0F,
        left_trigger, right_trigger,
        left_motor, right_motor,
        0xFF, 0x00, 0xEB
    };

    IOReturn ret = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x03, report, sizeof(report));

    // Throttle logging — only log if values changed and telemetry logging enabled
    static uint8_t last_l = 0, last_r = 0;
    if (g_cfg.log_telemetry && (left_motor != last_l || right_motor != last_r)) {
        viblog("rumble: L=%d R=%d -> %d", left_motor, right_motor, ret);
        last_l = left_motor;
        last_r = right_motor;
    }

    return ret;
}

static void stop_motors(void) {
    if (g_xbox_device) {
        viblog("Stopping motors (cleanup)");
        uint8_t report[9] = {0x03, 0x0F, 0, 0, 0, 0, 0xFF, 0x00, 0xEB};
        IOHIDDeviceSetReport(g_xbox_device, kIOHIDReportTypeOutput, 0x03, report, sizeof(report));
        usleep(50000);
        IOHIDDeviceSetReport(g_xbox_device, kIOHIDReportTypeOutput, 0x03, report, sizeof(report));
    }
}

static void signal_handler(int sig) {
    stop_motors();
    _exit(0);
}

static void send_test_vibration(IOHIDDeviceRef device) {
    viblog("Test vibration: sending...");
    send_xbox_rumble(device, 50, 30, 0, 0);
    usleep(200000);
    send_xbox_rumble(device, 0, 0, 0, 0);
    usleep(100000);
    send_xbox_rumble(device, 30, 20, 0, 0);
    usleep(150000);
    send_xbox_rumble(device, 0, 0, 0, 0);
    viblog("Test vibration: done");
}

// ============ EGO Engine Telemetry ============

// Codemasters EGO engine UDP telemetry — 66 floats (264 bytes)
// Confirmed format from GRID Autosport with extradata=3
#define TEL_TIME             0
#define TEL_LAP_TIME         1
#define TEL_LAP_DISTANCE     2
#define TEL_TOTAL_DISTANCE   3
#define TEL_X                4
#define TEL_Y                5
#define TEL_Z                6
#define TEL_SPEED            7   // m/s
#define TEL_XV               8
#define TEL_YV               9
#define TEL_ZV              10
#define TEL_XR              11   // right direction (unit vector)
#define TEL_YR              12
#define TEL_ZR              13
#define TEL_XD              14   // forward direction (unit vector)
#define TEL_YD              15
#define TEL_ZD              16
#define TEL_SUSP_POS_RL     17   // suspension position (4 wheels)
#define TEL_SUSP_POS_RR     18
#define TEL_SUSP_POS_FL     19
#define TEL_SUSP_POS_FR     20
#define TEL_SUSP_VEL_RL     21   // suspension velocity (4 wheels)
#define TEL_SUSP_VEL_RR     22
#define TEL_SUSP_VEL_FL     23
#define TEL_SUSP_VEL_FR     24
#define TEL_WHEEL_SPEED_RL  25   // wheel speed (4 wheels)
#define TEL_WHEEL_SPEED_RR  26
#define TEL_WHEEL_SPEED_FL  27
#define TEL_WHEEL_SPEED_FR  28
#define TEL_THROTTLE        29   // 0-1
#define TEL_STEER           30   // -1 to 1
#define TEL_BRAKE           31   // 0-1
#define TEL_CLUTCH          32
#define TEL_GEAR            33
#define TEL_GFORCE_LAT      34
#define TEL_GFORCE_LON      35
#define TEL_LAP             36
#define TEL_ENGINE_RATE     37   // rad/s (NOT RPM!)

#define TEL_MIN_FLOATS      38

// ============ Vibration Generator ============

static float g_motor_left = 0;
static float g_motor_right = 0;
static volatile int g_tel_alive = 0;  // watchdog: set by telemetry, cleared by watchdog

static int g_pkt_num = 0;
static float g_prev_gf = 0;
static float g_impact_hold = 0;  // separate slow-decay for impacts

static void process_telemetry(const float *d, int nf) {
    if (nf < TEL_MIN_FLOATS || !g_xbox_device) return;

    g_tel_alive = 1;
    g_pkt_num++;

    float speed = d[TEL_SPEED];
    float speed_kmh = speed * 3.6f;
    float gforce_lat = d[TEL_GFORCE_LAT];
    float gforce_lon = d[TEL_GFORCE_LON];
    float throttle = d[TEL_THROTTLE];
    float brake = d[TEL_BRAKE];
    float steer = d[TEL_STEER];
    float engine_rads = d[TEL_ENGINE_RATE];
    float rpm = engine_rads * 60.0f / (2.0f * M_PI);
    float gear = d[TEL_GEAR];

    // Suspension velocity (absolute average)
    float susp_vel_avg = (fabsf(d[TEL_SUSP_VEL_RL]) + fabsf(d[TEL_SUSP_VEL_RR]) +
                           fabsf(d[TEL_SUSP_VEL_FL]) + fabsf(d[TEL_SUSP_VEL_FR])) / 4.0f;

    // Wheel speeds and slip
    float whl_rl = fabsf(d[TEL_WHEEL_SPEED_RL]);
    float whl_rr = fabsf(d[TEL_WHEEL_SPEED_RR]);
    float whl_fl = fabsf(d[TEL_WHEEL_SPEED_FL]);
    float whl_fr = fabsf(d[TEL_WHEEL_SPEED_FR]);
    float avg_whl = (whl_rl + whl_rr + whl_fl + whl_fr) / 4.0f;

    // --- Effect 1: Impact (crash/hit) ---
    // Hybrid: sudden G-spike (delta) for car contacts + absolute for wall crashes
    float gf_total = sqrtf(gforce_lat * gforce_lat + gforce_lon * gforce_lon);
    float gf_delta = gf_total - g_prev_gf;  // positive = sudden increase
    float impact = 0;

    // A) Sudden spike (car contact, bump)
    if (gf_delta > g_cfg.impact_delta_threshold && gf_total > 1.5f) {
        impact = clampf((gf_delta - g_cfg.impact_delta_threshold) * 80.0f, 0, 100);
    }

    // B) Massive absolute G (wall crash)
    if (gf_total > g_cfg.impact_abs_threshold) {
        float abs_impact = clampf((gf_total - g_cfg.impact_abs_threshold) * 50.0f, 0, 100);
        if (abs_impact > impact) impact = abs_impact;
    }

    // C) Hard deceleration (wall crash): only when NOT player-braking
    if (gforce_lon < -3.0f && brake < 0.3f) {
        float decel_impact = clampf((-gforce_lon - 3.0f) * 50.0f, 0, 100);
        if (decel_impact > impact) impact = decel_impact;
    }

    impact *= g_cfg.impact * g_cfg.overall;
    impact = clampf(impact, 0, 100);

    g_prev_gf = gf_total;

    // Impact hold: new impact overrides, then slow decay
    if (impact > g_impact_hold) {
        g_impact_hold = impact;
    } else {
        g_impact_hold *= g_cfg.impact_hold;
        if (g_impact_hold < 3.0f) g_impact_hold = 0;
    }
    impact = g_impact_hold;

    // --- Effect 2: Cornering force (lateral G) ---
    float cornering = 0;
    if (fabsf(gforce_lat) > 0.8f && speed_kmh > 30.0f) {
        cornering = clampf((fabsf(gforce_lat) - 0.8f) * 12.0f, 0, 25);
        cornering *= g_cfg.cornering * g_cfg.overall;
    }

    // --- Effect 3: Surface / Road roughness ---
    float surface = 0;
    if (speed_kmh > 10.0f && susp_vel_avg > g_cfg.surface_threshold) {
        surface = clampf((susp_vel_avg - g_cfg.surface_threshold) * 0.4f, 0, 50);
        surface *= g_cfg.surface * g_cfg.overall;
    }

    // --- Effect 4: Wheel slip / Skid ---
    float slip_diff = fabsf(avg_whl - speed);
    float slip = 0;
    if (speed_kmh > 15.0f && slip_diff > g_cfg.slip_threshold) {
        slip = clampf((slip_diff - g_cfg.slip_threshold) * 6.0f, 0, 70);
        slip *= g_cfg.slip * g_cfg.overall;
    }

    // --- Effect 5: Engine rumble ---
    float engine = 0;
    if (rpm > g_cfg.engine_rpm_threshold && speed_kmh > 5.0f) {
        engine = clampf((rpm - g_cfg.engine_rpm_threshold) / 300.0f, 0, 15);
        engine *= clampf(throttle, 0.3f, 1.0f);
        engine *= g_cfg.engine * g_cfg.overall;
    }

    // --- Effect 6: Braking vibration ---
    float braking = 0;
    if (brake > 0.3f && speed_kmh > 30.0f) {
        braking = clampf((brake - 0.3f) * 50.0f, 0, 40);
        braking *= g_cfg.brake * g_cfg.overall;
    }

    // --- Combine ---
    // Left motor (heavy): impacts, braking, surface, cornering
    // Right motor (light): engine, slip, surface, cornering
    float tgt_l = impact + surface * 0.7f + braking * 0.9f + slip * 0.4f + cornering * 0.6f;
    float tgt_r = impact * 0.7f + surface * 0.5f + slip * 0.8f + engine + braking * 0.3f + cornering * 0.4f;
    tgt_l = clampf(tgt_l, 0, 100);
    tgt_r = clampf(tgt_r, 0, 100);

    g_motor_left  = g_motor_left * 0.3f + tgt_l * 0.7f;
    g_motor_right = g_motor_right * 0.3f + tgt_r * 0.7f;

    uint8_t ml = (g_motor_left  < g_cfg.dead_zone) ? 0 : (uint8_t)g_motor_left;
    uint8_t mr = (g_motor_right < g_cfg.dead_zone) ? 0 : (uint8_t)g_motor_right;

    // DIAG: log every 10th packet (~3 per second), only when enabled
    if (g_cfg.log_telemetry && g_pkt_num % 10 == 0) {
        viblog("D[%d] spd=%.0f rpm=%.0f g=%.0f thr=%.2f brk=%.2f str=%.2f Gf=%.2f dGf=%.2f suspV=%.0f wSlip=%.1f | imp=%.0f cor=%.0f surf=%.0f slip=%.0f eng=%.0f brk_e=%.0f -> L=%d R=%d",
               g_pkt_num, speed_kmh, rpm, gear, throttle, brake, steer,
               gf_total, gf_delta, susp_vel_avg, slip_diff,
               impact, cornering, surface, slip, engine, braking, ml, mr);
    }

    send_xbox_rumble(g_xbox_device, ml, mr, 0, 0);
}

// Watchdog: if no telemetry for ~1 second, zero the motors
static void *watchdog_thread(void *arg) {
    while (1) {
        usleep(500000);  // check every 500ms (worst case ~1s delay)
        if (g_tel_alive) {
            g_tel_alive = 0;
        } else {
            // No telemetry received — game probably exited or paused
            if (g_motor_left > 0 || g_motor_right > 0) {
                viblog("Watchdog: no telemetry, stopping motors");
                g_motor_left = 0;
                g_motor_right = 0;
                if (g_xbox_device) {
                    send_xbox_rumble(g_xbox_device, 0, 0, 0, 0);
                }
            }
        }
    }
    return NULL;
}

// ============ UDP Telemetry Listener ============

static void *telemetry_thread(void *arg) {
    viblog("Telemetry thread started, binding UDP port 20777...");

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        viblog("ERROR: socket() failed: %d", sock);
        return NULL;
    }

    int reuse = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(20777);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        viblog("ERROR: bind() to port 20777 failed");
        close(sock);
        return NULL;
    }

    viblog("UDP listener ready on 127.0.0.1:20777");

    uint8_t buf[1024];
    int pkt_count = 0;

    while (1) {
        ssize_t n = recv(sock, buf, sizeof(buf), 0);
        if (n <= 0) { usleep(1000); continue; }

        pkt_count++;
        int num_floats = (int)(n / sizeof(float));
        float *data = (float *)buf;

        // Log first packet for diagnostics
        if (pkt_count == 1) {
            viblog("First UDP packet: %zd bytes (%d floats)", n, num_floats);
        }

        // Process and generate vibration
        if (num_floats >= TEL_MIN_FLOATS) {
            process_telemetry(data, num_floats);
        }
    }

    close(sock);
    return NULL;
}

// ============ Xbox Controller Discovery ============

static void device_matched(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    uint16_t vid = 0, pid = 0;
    CFNumberRef vidRef = (CFNumberRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDVendorIDKey));
    CFNumberRef pidRef = (CFNumberRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey));
    if (vidRef) CFNumberGetValue(vidRef, kCFNumberSInt16Type, &vid);
    if (pidRef) CFNumberGetValue(pidRef, kCFNumberSInt16Type, &pid);

    CFStringRef nameRef = (CFStringRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    char name[128] = "Unknown";
    if (nameRef) CFStringGetCString(nameRef, name, sizeof(name), kCFStringEncodingUTF8);

    viblog("HID device matched: %04X:%04X '%s'", vid, pid, name);

    if (is_xbox_controller(vid, pid)) {
        viblog("*** Xbox controller found! PID=0x%04X ***", pid);
        g_xbox_device = device;
        g_xbox_pid = pid;

        if (!g_test_sent && g_cfg.test_on_start) {
            g_test_sent = 1;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                           dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                if (g_xbox_device) {
                    send_test_vibration(g_xbox_device);
                }
            });
        }
    }
}

static void device_removed(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    uint16_t vid = 0, pid = 0;
    CFNumberRef vidRef = (CFNumberRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDVendorIDKey));
    CFNumberRef pidRef = (CFNumberRef)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey));
    if (vidRef) CFNumberGetValue(vidRef, kCFNumberSInt16Type, &vid);
    if (pidRef) CFNumberGetValue(pidRef, kCFNumberSInt16Type, &pid);

    viblog("HID device removed: %04X:%04X", vid, pid);

    if (device == g_xbox_device) {
        viblog("Xbox controller disconnected");
        g_xbox_device = NULL;
        g_test_sent = 0;
    }
}

static void *controller_discovery_thread(void *arg) {
    viblog("Controller discovery thread started");
    sleep(2);

    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!manager) {
        viblog("ERROR: failed to create IOHIDManager");
        return NULL;
    }

    CFMutableDictionaryRef match1 = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int page1 = kHIDPage_GenericDesktop;
    int usage_gamepad = kHIDUsage_GD_GamePad;
    CFNumberRef pageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page1);
    CFNumberRef usageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage_gamepad);
    CFDictionarySetValue(match1, CFSTR(kIOHIDDeviceUsagePageKey), pageNum);
    CFDictionarySetValue(match1, CFSTR(kIOHIDDeviceUsageKey), usageNum);

    CFMutableDictionaryRef match2 = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int usage_joystick = kHIDUsage_GD_Joystick;
    CFNumberRef usageNum2 = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage_joystick);
    CFDictionarySetValue(match2, CFSTR(kIOHIDDeviceUsagePageKey), pageNum);
    CFDictionarySetValue(match2, CFSTR(kIOHIDDeviceUsageKey), usageNum2);

    CFMutableDictionaryRef match3 = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int usage_multi = kHIDUsage_GD_MultiAxisController;
    CFNumberRef usageNum3 = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage_multi);
    CFDictionarySetValue(match3, CFSTR(kIOHIDDeviceUsagePageKey), pageNum);
    CFDictionarySetValue(match3, CFSTR(kIOHIDDeviceUsageKey), usageNum3);

    CFMutableArrayRef matchArray = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    CFArrayAppendValue(matchArray, match1);
    CFArrayAppendValue(matchArray, match2);
    CFArrayAppendValue(matchArray, match3);

    IOHIDManagerSetDeviceMatchingMultiple(manager, matchArray);
    IOHIDManagerRegisterDeviceMatchingCallback(manager, device_matched, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(manager, device_removed, NULL);

    IOReturn ret = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    viblog("IOHIDManager open: %d", ret);

    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    viblog("HID manager scheduled, entering run loop");

    CFSetRef devices = IOHIDManagerCopyDevices(manager);
    if (devices) {
        CFIndex count = CFSetGetCount(devices);
        viblog("Already connected devices: %ld", (long)count);
        CFTypeRef *devArray = (CFTypeRef *)malloc(count * sizeof(CFTypeRef));
        CFSetGetValues(devices, devArray);
        for (CFIndex i = 0; i < count; i++) {
            device_matched(NULL, kIOReturnSuccess, NULL, (IOHIDDeviceRef)devArray[i]);
        }
        free(devArray);
        CFRelease(devices);
    }

    CFRunLoopRun();

    CFRelease(matchArray);
    CFRelease(match1);
    CFRelease(match2);
    CFRelease(match3);
    CFRelease(pageNum);
    CFRelease(usageNum);
    CFRelease(usageNum2);
    CFRelease(usageNum3);

    return NULL;
}

// ============ Entry Point ============

__attribute__((constructor))
static void grid_vibfix_init(void) {
    find_install_dir();

    viblog("=== GRID Autosport Vibration Fix v" VERSION " loaded (pid=%d) ===", getpid());
    viblog("Install dir: %s", g_install_dir);

    load_config();

    // Register cleanup handlers to stop motors on exit
    atexit(stop_motors);
    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);
    signal(SIGHUP, signal_handler);

    pthread_t hid_thread;
    pthread_create(&hid_thread, NULL, controller_discovery_thread, NULL);
    pthread_detach(hid_thread);

    pthread_t tel_thread;
    pthread_create(&tel_thread, NULL, telemetry_thread, NULL);
    pthread_detach(tel_thread);

    pthread_t wd_thread;
    pthread_create(&wd_thread, NULL, watchdog_thread, NULL);
    pthread_detach(wd_thread);
}
