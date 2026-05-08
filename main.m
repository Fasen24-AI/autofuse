// AutoFuse — macOS menu-bar app wrapping `mount.sh` / `discover.sh`.
//
// Architecture (why everything lives in a single AppDelegate):
//   - This is a menu-bar-only background app. There is exactly ONE long-lived
//     controller (AppDelegate). Retain cycles in dispatch blocks capturing
//     `self` are therefore practically harmless — the delegate outlives the
//     process. Dialog windows (Add/Edit, Setup Wizard, Preferences) are the
//     only short-lived controllers; they use associated objects (see keys
//     below) to attach transient state to the NSWindow instead of subclassing.
//   - All shell work happens through `runScript:` / `runDiscover:` which
//     launch NSTask with array arguments (no shell interpolation). Stdout is
//     collected off the main thread, parsed on the main thread, then applied
//     to UI state.
//   - Network-change recovery: a Darwin-notify observer (C callback) triggers
//     a debounced `autoHealCheck` that calls `panic-unmount-all` if every
//     configured host goes unreachable, avoiding Finder freezes when WiFi
//     drops.
//   - Sparkle is OPTIONAL: everything touching `<Sparkle/Sparkle.h>` is guarded
//     by `#if SPARKLE_AVAILABLE`. The app builds and ships cleanly without
//     Sparkle installed; `brew install sparkle` + rebuild enables updates.
//
// ARC is on (`-fobjc-arc`). Thread rule: UI work ONLY on main queue.

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <UserNotifications/UserNotifications.h>
#import <ServiceManagement/ServiceManagement.h>
#import <sys/param.h>
#import <sys/mount.h>   // getmntinfo / statfs — native, subprocess-free mount detection (energy)

#if __has_include(<Sparkle/Sparkle.h>)
#import <Sparkle/Sparkle.h>
#define SPARKLE_AVAILABLE 1
#else
#define SPARKLE_AVAILABLE 0
#endif

// ─── Associated Object Keys ────────────────────────────────────────────────

static const char kFieldsKey;
static const char kWindowKey;
static const char kEditModeKey;
static const char kWizardStepKey;
static const char kWizardDataKey;

// ─── Data Models ────────────────────────────────────────────────────────────

@interface WSDisk : NSObject
@property (nonatomic, copy) NSString *letter;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *remotePath;
// atomic: read on the main thread (updateIcon/buildMenu) while a background
// refresh writes them — atomic accessors prevent a torn read / use-after-free
// on the copied NSString.
@property (atomic, copy) NSString *status;      // mounted / unmounted / stale
@property (atomic, copy) NSString *mountPoint;
@end
@implementation WSDisk
@end

@interface WSHost : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *lanIP;
@property (nonatomic, copy) NSString *vpnIP;
@property (nonatomic, copy) NSString *macAddress;
@property (nonatomic, copy) NSString *disksRaw;
@property (nonatomic, copy) NSString *reachability;  // lan / vpn / offline
@property (nonatomic, strong) NSMutableArray<WSDisk *> *disks;
@end
@implementation WSHost
- (instancetype)init {
    self = [super init];
    if (self) { _disks = [NSMutableArray new]; _reachability = @"unknown"; }
    return self;
}
@end

// Forward declarations
void networkChangeCallback(CFNotificationCenterRef center, void *observer,
    CFNotificationName name, const void *object, CFDictionaryRef userInfo);

// ─── App Delegate ───────────────────────────────────────────────────────────

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMutableArray<WSHost *> *hosts;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) NSTimer *healTimer;
// Adaptive-cadence state (energy). Base intervals cached from config; the
// applied multiplier lets pollStatus skip rescheduling when nothing changed.
@property (nonatomic, assign) NSInteger basePollSec;
@property (nonatomic, assign) NSInteger baseHealSec;
@property (nonatomic, assign) double     appliedCadenceMult;
@property (nonatomic, copy)   NSString *scriptPath;
@property (nonatomic, copy)   NSString *discoverPath;
@property (nonatomic, copy)   NSString *configPath;
@property (nonatomic, assign) NSInteger operationCount;  // Atomic counter instead of single bool
@property (nonatomic, strong) NSTimer *networkDebounceTimer;  // Debounce for network changes
@property (nonatomic, assign) BOOL dependenciesChecked;
@property (nonatomic, copy)   NSString *vpnStatus;  // VPN status line for menu display
@property (nonatomic, assign) BOOL startsAtLogin;
@property (nonatomic, assign) BOOL showLatency;
@property (atomic, assign) double cachedWorstLatencyMs;   // measured off-main (H2)
@property (atomic, assign) BOOL latencyMeasureInFlight;
@property (nonatomic, strong) NSWindow *preferencesWindow;
@property (nonatomic, strong) NSWindow *wizardWindow;
// Per-disk auto-heal backoff. Key "ws/letter" (e.g. "ml-workstation/D") maps to
// the number of consecutive heal failures; the retry interval is
// base * 2^failures, capped at HEAL_BACKOFF_MAX_SEC. Resets to 0 on
// any successful heal. Prevents the 120s timer from hammering a
// persistently broken workstation forever (wasted CPU + log noise).
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *healFailCount;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *healLastAttempt;
#if SPARKLE_AVAILABLE
@property (nonatomic, strong) SPUStandardUpdaterController *updaterController;
#endif
@end

@implementation AppDelegate

// ─── SF Symbol Helper ──────────────────────────────────────────────────────

- (NSImage *)sfSymbol:(NSString *)name size:(CGFloat)size color:(NSColor *)color {
    NSImage *img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!img) return nil;
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightRegular];
    img = [img imageWithSymbolConfiguration:cfg];
    if (color) {
        img = [img copy];
        [img lockFocus];
        [color set];
        NSRect r = NSMakeRect(0, 0, img.size.width, img.size.height);
        NSRectFillUsingOperation(r, NSCompositingOperationSourceAtop);
        [img unlockFocus];
    }
    return img;
}

// ─── Discover Script Runner ────────────────────────────────────────────────

// Launch `discover.sh` with the given argv and return collected stdout.
// Three overloads: `:` uses a 15s default timeout, `:timeout:` overrides it,
// and an internal `:timeout:error:` variant also surfaces stderr separately.
// The actual NSTask launch happens in the full overload below; the short
// ones are trivial convenience wrappers. All three use array arguments
// (never shell string interpolation) so workstation names and IPs entered
// by the user cannot inject shell metacharacters.
- (NSString *)runDiscover:(NSArray *)args {
    return [self runDiscover:args timeout:15];
}

- (NSString *)runDiscover:(NSArray *)args timeout:(NSTimeInterval)timeout {
    NSTask *t = [NSTask new];
    t.launchPath = @"/bin/bash";
    t.arguments = [@[self.discoverPath] arrayByAddingObjectsFromArray:args];
    t.environment = @{
        @"PATH": @"/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        @"HOME": NSHomeDirectory()
    };
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    t.standardOutput = outPipe;
    t.standardError  = errPipe;

    __block NSData *outData = nil;

    @try {
        [t launch];

        dispatch_group_t readGroup = dispatch_group_create();
        dispatch_group_enter(readGroup);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            outData = [outPipe.fileHandleForReading readDataToEndOfFile];
            dispatch_group_leave(readGroup);
        });
        dispatch_group_enter(readGroup);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [errPipe.fileHandleForReading readDataToEndOfFile];
            dispatch_group_leave(readGroup);
        });

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [t waitUntilExit];
            dispatch_semaphore_signal(sem);
        });
        long result = dispatch_semaphore_wait(sem,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
        if (result != 0) {
            [t terminate];
            [outPipe.fileHandleForReading closeFile];
            [errPipe.fileHandleForReading closeFile];
            return @"";
        }
        dispatch_group_wait(readGroup, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    }
    @catch (NSException *e) { return @""; }

    return [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] ?: @"";
}

// ─── Notifications ─────────────────────────────────────────────────────────

- (void)postNotificationWithTitle:(NSString *)title body:(NSString *)body {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = title;
    content.body = body;
    content.sound = [UNNotificationSound defaultSound];
    NSString *identifier = [NSString stringWithFormat:@"wm-%f", [NSDate timeIntervalSinceReferenceDate]];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                          content:content
                                                                          trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request
                                                           withCompletionHandler:nil];
}

// ─── Script Runner ──────────────────────────────────────────────────────────

- (NSString *)runScript:(NSArray *)args {
    return [self runScript:args timeout:30];
}

- (NSString *)runScript:(NSArray *)args timeout:(NSTimeInterval)timeout {
    NSTask *t = [NSTask new];
    t.launchPath = @"/bin/bash";
    t.arguments = [@[self.scriptPath] arrayByAddingObjectsFromArray:args];
    t.environment = @{
        @"PATH": @"/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        @"HOME": NSHomeDirectory()
    };
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    t.standardOutput = outPipe;
    t.standardError  = errPipe;

    // Read data before waiting to prevent pipe deadlock (#7)
    __block NSData *outData = nil;
    __block NSData *errData = nil;

    @try {
        [t launch];

        // Read output in background to prevent blocking after timeout (#7)
        dispatch_group_t readGroup = dispatch_group_create();

        dispatch_group_enter(readGroup);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            outData = [outPipe.fileHandleForReading readDataToEndOfFile];
            dispatch_group_leave(readGroup);
        });

        dispatch_group_enter(readGroup);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            errData = [errPipe.fileHandleForReading readDataToEndOfFile];
            dispatch_group_leave(readGroup);
        });

        // Wait for task with timeout
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [t waitUntilExit];
            dispatch_semaphore_signal(sem);
        });
        long result = dispatch_semaphore_wait(sem,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
        if (result != 0) {
            // Timeout — kill the task and close pipe handles
            [t terminate];
            [outPipe.fileHandleForReading closeFile];
            [errPipe.fileHandleForReading closeFile];
            return @"timeout";
        }

        // Wait for reads to complete (they should finish quickly after task exits)
        dispatch_group_wait(readGroup, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    }
    @catch (NSException *e) { return @""; }

    NSString *output = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] ?: @"";
    return output;
}

// Variant that captures both stdout and stderr
- (NSString *)runScript:(NSArray *)args timeout:(NSTimeInterval)timeout error:(NSString **)errorOutput {
    NSTask *t = [NSTask new];
    t.launchPath = @"/bin/bash";
    t.arguments = [@[self.scriptPath] arrayByAddingObjectsFromArray:args];
    t.environment = @{
        @"PATH": @"/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        @"HOME": NSHomeDirectory()
    };
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    t.standardOutput = outPipe;
    t.standardError  = errPipe;

    __block NSData *outData = nil;
    __block NSData *errData = nil;

    @try {
        [t launch];

        dispatch_group_t readGroup = dispatch_group_create();

        dispatch_group_enter(readGroup);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            outData = [outPipe.fileHandleForReading readDataToEndOfFile];
            dispatch_group_leave(readGroup);
        });

        dispatch_group_enter(readGroup);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            errData = [errPipe.fileHandleForReading readDataToEndOfFile];
            dispatch_group_leave(readGroup);
        });

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [t waitUntilExit];
            dispatch_semaphore_signal(sem);
        });
        long result = dispatch_semaphore_wait(sem,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
        if (result != 0) {
            [t terminate];
            [outPipe.fileHandleForReading closeFile];
            [errPipe.fileHandleForReading closeFile];
            if (errorOutput) *errorOutput = @"Operation timed out";
            return @"timeout";
        }

        dispatch_group_wait(readGroup, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    }
    @catch (NSException *e) {
        if (errorOutput) *errorOutput = e.reason ?: @"Unknown error";
        return @"";
    }

    if (errorOutput) {
        *errorOutput = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"";
    }
    return [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] ?: @"";
}

// ─── Host Loading & Status ──────────────────────────────────────────────────

- (void)loadHosts {
    self.hosts = [NSMutableArray new];
    NSString *out = [self runScript:@[@"list"]];
    for (NSString *line in [out componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if (line.length == 0) continue;
        NSArray *parts = [line componentsSeparatedByString:@"|"];
        if (parts.count < 4) continue;
        WSHost *h = [WSHost new];
        h.name       = parts[0];
        h.lanIP      = parts[1];
        h.vpnIP      = parts[2];
        h.disksRaw   = parts[3];
        h.macAddress  = parts.count > 4 ? parts[4] : @"";
        NSString *disksOut = [self runScript:@[@"disks", h.name]];
        for (NSString *dl in [disksOut componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            if (dl.length == 0) continue;
            NSArray *dp = [dl componentsSeparatedByString:@"|"];
            if (dp.count < 3) continue;
            WSDisk *disk = [WSDisk new];
            disk.letter     = dp[0];
            disk.label      = dp[1];
            disk.remotePath = dp[2];
            disk.status     = @"unmounted";
            disk.mountPoint = @"";
            [h.disks addObject:disk];
        }
        [self.hosts addObject:h];
    }
}

- (void)refreshStatus {
    NSString *out = [self runScript:@[@"status-all"] timeout:15];
    if ([out isEqualToString:@"timeout"]) return;

    for (NSString *line in [out componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if (line.length == 0) continue;
        NSArray *parts = [line componentsSeparatedByString:@"|"];
        if (parts.count < 3) continue;
        NSString *hostName = parts[0];
        NSString *diskLetter = parts[1];
        NSString *statusFull = parts[2];
        NSArray *sp = [statusFull componentsSeparatedByString:@":"];
        NSString *st = sp[0];
        NSString *mp = sp.count > 1 ? [[sp subarrayWithRange:NSMakeRange(1, sp.count - 1)]
                                        componentsJoinedByString:@":"] : @"";
        for (WSHost *h in self.hosts) {
            if (![h.name isEqualToString:hostName]) continue;
            for (WSDisk *d in h.disks) {
                if ([d.letter isEqualToString:diskLetter]) {
                    d.status = st;
                    d.mountPoint = mp;
                }
            }
        }
    }
    [self updateIcon];
}

- (double)measureWorstLatency {
    double worst = 0;
    for (WSHost *h in self.hosts) {
        for (WSDisk *d in h.disks) {
            if (![d.status isEqualToString:@"mounted"] || d.mountPoint.length == 0) continue;
            NSDate *start = [NSDate date];
            [[NSFileManager defaultManager] contentsOfDirectoryAtPath:d.mountPoint error:nil];
            double ms = -[start timeIntervalSinceNow] * 1000.0;
            if (ms > worst) worst = ms;
        }
    }
    return worst;
}

// Measure worst-case mount latency on a background queue and cache it, so
// updateIcon (main thread) never blocks on contentsOfDirectoryAtPath against a
// dead sshfs mount — that read can hang for the whole keepalive window and
// would freeze the menu bar, the exact freeze AutoFuse exists to prevent.
- (void)refreshLatencyCache {
    if (!self.showLatency || self.latencyMeasureInFlight) return;
    self.latencyMeasureInFlight = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        self.cachedWorstLatencyMs = [self measureWorstLatency];
        self.latencyMeasureInFlight = NO;
    });
}

- (void)updateIcon {
    // AppKit (statusItem.button.*) is main-thread-only. menuWillOpen and other
    // background refreshes call through here, so re-dispatch off-main callers.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self updateIcon]; });
        return;
    }
    BOOL anyMounted = NO;
    BOOL anyStale = NO;
    for (WSHost *h in self.hosts) {
        for (WSDisk *d in h.disks) {
            if ([d.status isEqualToString:@"mounted"]) anyMounted = YES;
            if ([d.status isEqualToString:@"stale"]) anyStale = YES;
        }
    }
    self.statusItem.button.title = @"";
    self.statusItem.button.attributedTitle = [[NSAttributedString alloc] initWithString:@""];
    if (self.operationCount > 0) {
        NSImage *icon = [self sfSymbol:@"arrow.triangle.2.circlepath" size:14 color:nil];
        if (icon) {
            [icon setTemplate:YES];
            self.statusItem.button.image = icon;
        } else {
            self.statusItem.button.image = nil;
            self.statusItem.button.title = @"⏳";
        }
    } else if (anyStale) {
        NSImage *icon = [self sfSymbol:@"externaldrive.fill.badge.exclamationmark" size:14 color:nil];
        if (icon) {
            [icon setTemplate:YES];
            self.statusItem.button.image = icon;
        } else {
            self.statusItem.button.image = nil;
            self.statusItem.button.title = @"⚠️";
        }
    } else if (anyMounted) {
        NSImage *icon = [self sfSymbol:@"externaldrive.fill.badge.checkmark" size:14 color:nil];
        if (icon) {
            [icon setTemplate:YES];
            self.statusItem.button.image = icon;
        } else {
            self.statusItem.button.image = nil;
            self.statusItem.button.title = @"💻";
        }
    } else {
        NSImage *icon = [self sfSymbol:@"externaldrive" size:14 color:nil];
        if (icon) {
            [icon setTemplate:YES];
            self.statusItem.button.image = icon;
        } else {
            self.statusItem.button.image = nil;
            self.statusItem.button.title = @"🖥";
        }
    }

    // Latency indicator
    if (self.showLatency && anyMounted) {
        double latency = self.cachedWorstLatencyMs;  // cached; refreshed off-main
        [self refreshLatencyCache];
        NSString *latencyText;
        NSColor *latencyColor;
        if (latency < 50) {
            latencyText = [NSString stringWithFormat:@" ● %.0fms", latency];
            latencyColor = [NSColor systemGreenColor];
        } else if (latency <= 200) {
            latencyText = [NSString stringWithFormat:@" ● %.0fms", latency];
            latencyColor = [NSColor systemYellowColor];
        } else {
            latencyText = @" ● slow";
            latencyColor = [NSColor systemRedColor];
        }
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: latencyColor
        };
        self.statusItem.button.attributedTitle = [[NSAttributedString alloc] initWithString:latencyText attributes:attrs];
    }

    // Tooltip
    NSInteger mountCount = 0, totalCount = 0;
    for (WSHost *h in self.hosts) {
        for (WSDisk *d in h.disks) {
            totalCount++;
            if ([d.status isEqualToString:@"mounted"]) mountCount++;
        }
    }
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"AutoFuse — %ld connected, %ld available", (long)mountCount, (long)(totalCount - mountCount)];
}

- (NSInteger)mountedCountForHost:(WSHost *)h {
    NSInteger c = 0;
    for (WSDisk *d in h.disks)
        if ([d.status isEqualToString:@"mounted"]) c++;
    return c;
}

- (BOOL)hasStaleForHost:(WSHost *)h {
    for (WSDisk *d in h.disks)
        if ([d.status isEqualToString:@"stale"]) return YES;
    return NO;
}

// ─── Claude Integration ─────────────────────────────────────────────────────

- (NSString *)detectNodePath {
    NSArray *paths = @[
        @"/opt/homebrew/bin/node",  // Apple Silicon Homebrew
        @"/usr/local/bin/node",      // Intel Homebrew
        @"/usr/bin/node"             // System install
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in paths) {
        if ([fm fileExistsAtPath:path]) {
            return path;
        }
    }
    // Try `which node`
    NSTask *t = [NSTask new];
    t.launchPath = @"/usr/bin/which";
    t.arguments = @[@"node"];
    NSPipe *pipe = [NSPipe pipe];
    t.standardOutput = pipe;
    @try {
        [t launch];
        [t waitUntilExit];
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        NSString *result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    @catch (NSException *e) {}
    return nil;
}

- (NSString *)getNodeVersion:(NSString *)nodePath {
    NSTask *t = [NSTask new];
    t.launchPath = nodePath;
    t.arguments = @[@"--version"];
    NSPipe *pipe = [NSPipe pipe];
    t.standardOutput = pipe;
    @try {
        [t launch];
        [t waitUntilExit];
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        NSString *result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    @catch (NSException *e) {}
    return nil;
}

- (BOOL)isMCPInstalled {
    NSString *configPath = [NSString stringWithFormat:@"%@/Library/Application Support/Claude/claude_desktop_config.json",
        NSHomeDirectory()];
    NSError *err = nil;
    NSData *data = [NSData dataWithContentsOfFile:configPath options:0 error:&err];
    if (!data) return NO;

    NSDictionary *config = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!config) return NO;

    NSDictionary *mcpServers = config[@"mcpServers"];
    return mcpServers && mcpServers[@"autofuse-mcp"] != nil;
}

- (void)showClaudeIntegration:(NSMenuItem *)sender {
    NSString *nodePath = [self detectNodePath];
    NSString *nodeVersion = nodePath ? [self getNodeVersion:nodePath] : nil;
    BOOL isMCPInstalled = [self isMCPInstalled];

    [NSApp activateIgnoringOtherApps:YES];

    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 500, 350)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    win.title = isMCPInstalled ? @"Claude Integration" : @"Claude Integration Setup";
    [win center];
    win.level = NSFloatingWindowLevel;
    win.delegate = self;
    // Under ARC the property holds the only strong ref; the default
    // releasedWhenClosed=YES makes the red-X close over-release it → dealloc →
    // crash on next open (we read .isVisible on a dead object). Keep it alive.
    win.releasedWhenClosed = NO;

    NSView *cv = [[NSView alloc] initWithFrame:win.contentView.bounds];
    cv.wantsLayer = YES;

    CGFloat y = win.contentView.bounds.size.height - 30;

    if (isMCPInstalled) {
        // State C: Already installed
        NSTextField *title = [[NSTextField alloc] initWithFrame:NSMakeRect(20, y, 460, 30)];
        title.stringValue = @"AutoFuse is connected to Claude Desktop";
        title.font = [NSFont boldSystemFontOfSize:16];
        title.bordered = NO;
        title.editable = NO;
        title.drawsBackground = NO;
        [cv addSubview:title];
        y -= 40;

        NSTextField *desc = [[NSTextField alloc] initWithFrame:NSMakeRect(20, y, 460, 60)];
        desc.stringValue = @"✓ MCP is installed and ready to use\n\nAutofuse provides 30+ tools for managing remote mounts, discovering workstations, and controlling Wake-on-LAN directly from Claude.";
        desc.font = [NSFont systemFontOfSize:12];
        desc.bordered = NO;
        desc.editable = NO;
        desc.drawsBackground = NO;
        [cv addSubview:desc];
        y -= 80;

        // Buttons
        NSButton *open = [[NSButton alloc] initWithFrame:NSMakeRect(20, 20, 150, 30)];
        open.title = @"Open Claude Desktop";
        open.bezelStyle = NSBezelStyleRounded;
        open.target = self;
        open.action = @selector(openClaudeDesktop:);
        [cv addSubview:open];

        NSButton *reinstall = [[NSButton alloc] initWithFrame:NSMakeRect(180, 20, 100, 30)];
        reinstall.title = @"Reinstall";
        reinstall.bezelStyle = NSBezelStyleRounded;
        reinstall.target = self;
        reinstall.action = @selector(reinstallMCP:);
        [cv addSubview:reinstall];

        NSButton *uninstall = [[NSButton alloc] initWithFrame:NSMakeRect(290, 20, 100, 30)];
        uninstall.title = @"Uninstall";
        uninstall.bezelStyle = NSBezelStyleRounded;
        uninstall.target = self;
        uninstall.action = @selector(uninstallMCP:);
        [cv addSubview:uninstall];

        NSButton *close = [[NSButton alloc] initWithFrame:NSMakeRect(400, 20, 80, 30)];
        close.title = @"Close";
        close.bezelStyle = NSBezelStyleRounded;
        close.target = win;
        close.action = @selector(close);
        [cv addSubview:close];
    } else if (!nodePath || !nodeVersion) {
        // State A: Node.js not installed
        NSTextField *title = [[NSTextField alloc] initWithFrame:NSMakeRect(20, y, 460, 30)];
        title.stringValue = @"Node.js Required";
        title.font = [NSFont boldSystemFontOfSize:16];
        title.bordered = NO;
        title.editable = NO;
        title.drawsBackground = NO;
        [cv addSubview:title];
        y -= 40;

        NSTextField *desc = [[NSTextField alloc] initWithFrame:NSMakeRect(20, y, 460, 80)];
        desc.stringValue = @"AutoFuse's Claude integration requires Node.js 18 or later.\n\nIt doesn't appear to be installed on your Mac. You can install it now via Homebrew (easiest) or manually.";
        desc.font = [NSFont systemFontOfSize:12];
        desc.bordered = NO;
        desc.editable = NO;
        desc.drawsBackground = NO;
        [cv addSubview:desc];
        y -= 100;

        NSButton *brew = [[NSButton alloc] initWithFrame:NSMakeRect(20, 60, 180, 30)];
        brew.title = @"Install via Homebrew";
        brew.bezelStyle = NSBezelStyleRounded;
        brew.target = self;
        brew.action = @selector(installNodeviaBrew:);
        [cv addSubview:brew];

        NSButton *manual = [[NSButton alloc] initWithFrame:NSMakeRect(210, 60, 180, 30)];
        manual.title = @"Visit nodejs.org";
        manual.bezelStyle = NSBezelStyleRounded;
        manual.target = self;
        manual.action = @selector(visitNodeWebsite:);
        [cv addSubview:manual];

        NSButton *checkAgain = [[NSButton alloc] initWithFrame:NSMakeRect(390, 60, 90, 30)];
        checkAgain.title = @"Check Again";
        checkAgain.bezelStyle = NSBezelStyleRounded;
        checkAgain.target = self;
        checkAgain.action = @selector(showClaudeIntegration:);
        [cv addSubview:checkAgain];

        NSButton *closeBtn = [[NSButton alloc] initWithFrame:NSMakeRect(410, 20, 80, 30)];
        closeBtn.title = @"Close";
        closeBtn.bezelStyle = NSBezelStyleRounded;
        closeBtn.target = win;
        closeBtn.action = @selector(close);
        [cv addSubview:closeBtn];
    } else {
        // State B: Node.js OK, MCP not installed
        NSTextField *title = [[NSTextField alloc] initWithFrame:NSMakeRect(20, y, 460, 30)];
        title.stringValue = @"Claude Integration Setup";
        title.font = [NSFont boldSystemFontOfSize:16];
        title.bordered = NO;
        title.editable = NO;
        title.drawsBackground = NO;
        [cv addSubview:title];
        y -= 40;

        NSTextField *status = [[NSTextField alloc] initWithFrame:NSMakeRect(20, y, 460, 20)];
        status.stringValue = [NSString stringWithFormat:@"✓ Node.js %@ detected", nodeVersion];
        status.font = [NSFont systemFontOfSize:11];
        status.bordered = NO;
        status.editable = NO;
        status.drawsBackground = NO;
        status.textColor = [NSColor systemGreenColor];
        [cv addSubview:status];
        y -= 30;

        NSTextField *desc = [[NSTextField alloc] initWithFrame:NSMakeRect(20, y, 460, 100)];
        desc.stringValue = @"Ready to install AutoFuse integration for Claude Desktop.\n\nThis will:\n1) Copy the MCP server to ~/.config/autofuse/mcp/\n2) Update Claude Desktop configuration\n3) Ask you to restart Claude";
        desc.font = [NSFont systemFontOfSize:12];
        desc.bordered = NO;
        desc.editable = NO;
        desc.drawsBackground = NO;
        [cv addSubview:desc];
        y -= 110;

        NSButton *install = [[NSButton alloc] initWithFrame:NSMakeRect(20, 30, 150, 30)];
        install.title = @"Install";
        install.bezelStyle = NSBezelStyleRounded;
        install.target = self;
        install.action = @selector(installMCPServer:);
        [cv addSubview:install];

        NSButton *cancel = [[NSButton alloc] initWithFrame:NSMakeRect(180, 30, 100, 30)];
        cancel.title = @"Cancel";
        cancel.bezelStyle = NSBezelStyleRounded;
        cancel.target = win;
        cancel.action = @selector(close);
        [cv addSubview:cancel];
    }

    win.contentView = cv;
    [win makeKeyAndOrderFront:nil];
}

- (void)installNodeviaBrew:(NSButton *)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Install Node.js";
    alert.informativeText = @"This will open Terminal to install Node.js via Homebrew.\n\nIf you don't have Homebrew installed, visit brew.sh first.";
    [alert addButtonWithTitle:@"Continue"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSString *script = @"if ! command -v brew &> /dev/null; then\n  echo 'Homebrew not found. Visit https://brew.sh'\n  exit 1\nfi\nbrew install node\necho 'Node.js installed successfully!'\n";

    NSTask *t = [NSTask new];
    t.launchPath = @"/usr/bin/open";
    t.arguments = @[@"-a", @"Terminal", @"-e", @"bash", @"-c", script];
    @try { [t launch]; } @catch (NSException *e) {}
}

- (void)visitNodeWebsite:(NSButton *)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://nodejs.org"]];
}

- (void)installMCPServer:(NSButton *)sender {
    NSString *appPath = [[NSBundle mainBundle] bundlePath];
    NSString *mcpSrc = [appPath stringByAppendingPathComponent:@"Contents/Resources/mcp"];
    NSString *mcpDst = [NSString stringWithFormat:@"%@/.config/autofuse/mcp", NSHomeDirectory()];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;

    // Create destination directory
    NSString *dstDir = [mcpDst stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:dstDir withIntermediateDirectories:YES attributes:nil error:&err];

    // Copy MCP bundle
    if ([fm fileExistsAtPath:mcpDst]) {
        [fm removeItemAtPath:mcpDst error:&err];
    }
    [fm copyItemAtPath:mcpSrc toPath:mcpDst error:&err];

    if (err) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"Installation Failed";
        a.informativeText = [NSString stringWithFormat:@"Could not copy MCP server: %@", err.localizedDescription];
        a.alertStyle = NSAlertStyleWarning;
        [a runModal];
        return;
    }

    // Update Claude config
    NSString *claudeConfigPath = [NSString stringWithFormat:@"%@/Library/Application Support/Claude/claude_desktop_config.json",
        NSHomeDirectory()];
    NSString *claudeConfigDir = [claudeConfigPath stringByDeletingLastPathComponent];

    [fm createDirectoryAtPath:claudeConfigDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSMutableDictionary *config = nil;
    if ([fm fileExistsAtPath:claudeConfigPath]) {
        NSData *data = [NSData dataWithContentsOfFile:claudeConfigPath options:0 error:&err];
        config = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&err];
    }
    if (!config) config = [NSMutableDictionary new];

    NSString *nodePath = [self detectNodePath];
    NSMutableDictionary *mcpServers = config[@"mcpServers"] ?: [NSMutableDictionary new];
    mcpServers[@"autofuse-mcp"] = @{
        @"command": @"node",
        @"args": @[[NSString stringWithFormat:@"%@/dist/index.js", mcpDst]],
        @"env": @{
            @"AUTOFUSE_MOUNT_SH": [appPath stringByAppendingPathComponent:@"Contents/Resources/mount.sh"],
            @"AUTOFUSE_DISCOVER_SH": [appPath stringByAppendingPathComponent:@"Contents/Resources/discover.sh"]
        }
    };
    config[@"mcpServers"] = mcpServers;

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:&err];
    if (err || ![jsonData writeToFile:claudeConfigPath options:NSDataWritingAtomic error:&err]) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"Configuration Failed";
        a.informativeText = [NSString stringWithFormat:@"Could not update Claude config: %@", err.localizedDescription];
        a.alertStyle = NSAlertStyleWarning;
        [a runModal];
        return;
    }

    NSAlert *success = [NSAlert new];
    success.messageText = @"Installation Complete";
    success.informativeText = @"AutoFuse MCP is now installed.\n\nPlease quit and reopen Claude Desktop to enable the integration.";
    success.alertStyle = NSAlertStyleInformational;
    [success runModal];
}

- (void)reinstallMCP:(NSButton *)sender {
    [self installMCPServer:sender];
}

- (void)uninstallMCP:(NSButton *)sender {
    NSAlert *confirm = [NSAlert new];
    confirm.messageText = @"Uninstall Claude Integration?";
    confirm.informativeText = @"This will remove AutoFuse from Claude Desktop configuration.";
    [confirm addButtonWithTitle:@"Uninstall"];
    [confirm addButtonWithTitle:@"Cancel"];
    if ([confirm runModal] != NSAlertFirstButtonReturn) return;

    NSString *claudeConfigPath = [NSString stringWithFormat:@"%@/Library/Application Support/Claude/claude_desktop_config.json",
        NSHomeDirectory()];
    NSError *err = nil;
    NSData *data = [NSData dataWithContentsOfFile:claudeConfigPath options:0 error:&err];
    NSMutableDictionary *config = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&err];

    if (config && config[@"mcpServers"]) {
        NSMutableDictionary *servers = config[@"mcpServers"];
        [servers removeObjectForKey:@"autofuse-mcp"];

        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:&err];
        [jsonData writeToFile:claudeConfigPath options:NSDataWritingAtomic error:&err];
    }

    NSAlert *done = [NSAlert new];
    done.messageText = @"Uninstalled";
    done.informativeText = @"AutoFuse has been removed from Claude Desktop. Restart Claude to complete.";
    [done runModal];
}

- (void)openClaudeDesktop:(NSButton *)sender {
    NSTask *t = [NSTask new];
    t.launchPath = @"/usr/bin/open";
    t.arguments = @[@"-a", @"Claude"];
    @try { [t launch]; } @catch (NSException *e) {}
}

// ─── Menu Building ──────────────────────────────────────────────────────────

// Rebuild the entire menu bar menu from current state. Called whenever the
// menu opens (see `menuWillOpen:`) so status indicators and disk counts
// reflect the latest `refreshStatus` pass. A full rebuild is intentional —
// in-place updates would require tracking every NSMenuItem the builder
// might have created under the many conditional branches (VPN section,
// workstations with variable disk counts, panic warnings, Setup Wizard
// shortcut, Claude Integration block, etc.). Rebuilding each open takes
// <20ms on current hardware and sidesteps the entire state-sync bug class.
// Ordering matters: VPN status first (top-of-menu context), then per-
// workstation sections with their disks, then global actions (Preferences,
// Setup, Log, Claude Integration), then Quit at the bottom.
- (void)buildMenu {
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;

    // VPN/Tailscale status at top
    if (self.vpnStatus.length > 0) {
        for (NSString *line in [self.vpnStatus componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            if (line.length == 0) continue;
            NSArray *parts = [line componentsSeparatedByString:@"|"];
            if (parts.count < 3) continue;
            NSString *iface = parts[0];
            NSString *ip = parts[1];
            NSString *vtype = parts[2];
            NSString *label = @"VPN";
            if ([vtype isEqualToString:@"tailscale"]) label = @"Tailscale";
            else if ([vtype isEqualToString:@"wireguard"]) label = @"WireGuard";
            else if ([vtype isEqualToString:@"wifiman"]) label = @"WiFiman";
            NSString *vpnTitle = [NSString stringWithFormat:@"\U0001F517 %@: Connected (%@)", label, ip];
            NSMenuItem *vpnItem = [[NSMenuItem alloc] initWithTitle:vpnTitle action:nil keyEquivalent:@""];
            vpnItem.enabled = NO;
            NSDictionary *vpnAttrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:11],
                NSForegroundColorAttributeName: [NSColor systemGreenColor]
            };
            vpnItem.attributedTitle = [[NSAttributedString alloc] initWithString:vpnTitle attributes:vpnAttrs];
            [menu addItem:vpnItem];
        }
        [menu addItem:[NSMenuItem separatorItem]];
    }

    // First-run: no workstations configured (#13)
    if (self.hosts.count == 0) {
        NSMenuItem *welcome = [[NSMenuItem alloc] initWithTitle:@"No workstations configured" action:nil keyEquivalent:@""];
        welcome.enabled = NO;
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
        };
        welcome.attributedTitle = [[NSAttributedString alloc] initWithString:@"No workstations configured" attributes:attrs];
        [menu addItem:welcome];

        NSMenuItem *hint = [[NSMenuItem alloc] initWithTitle:@"Click 'Add Computer...' below to get started" action:nil keyEquivalent:@""];
        hint.enabled = NO;
        [menu addItem:hint];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    for (WSHost *h in self.hosts) {
        NSInteger mc = [self mountedCountForHost:h];
        BOOL hasStale = [self hasStaleForHost:h];
        NSString *staleTag = hasStale ? @" [!]" : @"";
        NSString *hostTitle = [NSString stringWithFormat:@"%@ (%@)  %ld/%ld%@",
                               h.name,
                               h.lanIP.length > 0 ? h.lanIP : h.vpnIP,
                               (long)mc, (long)h.disks.count, staleTag];

        NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:hostTitle action:nil keyEquivalent:@""];
        NSDictionary *boldAttrs = @{NSFontAttributeName: [NSFont boldSystemFontOfSize:13]};
        header.attributedTitle = [[NSAttributedString alloc] initWithString:hostTitle attributes:boldAttrs];
        [menu addItem:header];

        // Disk entries
        for (WSDisk *d in h.disks) {
            BOOL isMounted = [d.status isEqualToString:@"mounted"];
            BOOL isStale   = [d.status isEqualToString:@"stale"];
            NSImage *diskIcon = nil;
            if (isMounted) {
                diskIcon = [self sfSymbol:@"circle.fill" size:12 color:[NSColor systemGreenColor]];
            } else if (isStale) {
                diskIcon = [self sfSymbol:@"exclamationmark.circle.fill" size:12 color:[NSColor systemYellowColor]];
            } else {
                diskIcon = [self sfSymbol:@"circle" size:12 color:nil];
            }
            NSString *title;
            if (isMounted) {
                title = [NSString stringWithFormat:@"   ● %@: — %@ — Connected", d.letter, d.label];
            } else if (isStale) {
                title = [NSString stringWithFormat:@"   ⚠ %@: — %@ — Connection Lost", d.letter, d.label];
            } else {
                title = [NSString stringWithFormat:@"   ○  %@: — %@", d.letter, d.label];
            }

            if (isMounted) {
                // Mounted: submenu with unmount/finder/terminal
                NSMenuItem *diskItem = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
                if (diskIcon) diskItem.image = diskIcon;
                NSMenu *diskMenu = [[NSMenu alloc] init];
                NSMenuItem *i1 = [[NSMenuItem alloc] initWithTitle:@"Disconnect" action:@selector(unmountDisk:) keyEquivalent:@""];
                i1.representedObject = @{@"host": h.name, @"disk": d.letter}; i1.target = self;
                [diskMenu addItem:i1];
                NSMenuItem *i2 = [[NSMenuItem alloc] initWithTitle:@"Show in Finder" action:@selector(openInFinder:) keyEquivalent:@""];
                i2.representedObject = d.mountPoint; i2.target = self;
                [diskMenu addItem:i2];
                NSMenuItem *i3 = [[NSMenuItem alloc] initWithTitle:@"Open Terminal Here" action:@selector(openInTerminal:) keyEquivalent:@""];
                i3.representedObject = d.mountPoint; i3.target = self;
                [diskMenu addItem:i3];
                diskItem.submenu = diskMenu;
                [menu addItem:diskItem];
            } else if (isStale) {
                // Stale: submenu with heal/force-unmount
                NSMenuItem *diskItem = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
                if (diskIcon) diskItem.image = diskIcon;
                NSMenu *diskMenu = [[NSMenu alloc] init];
                NSMenuItem *i1 = [[NSMenuItem alloc] initWithTitle:@"Reconnect" action:@selector(healDisk:) keyEquivalent:@""];
                i1.representedObject = @{@"host": h.name, @"disk": d.letter}; i1.target = self;
                [diskMenu addItem:i1];
                NSMenuItem *i2 = [[NSMenuItem alloc] initWithTitle:@"Force Disconnect" action:@selector(unmountDisk:) keyEquivalent:@""];
                i2.representedObject = @{@"host": h.name, @"disk": d.letter}; i2.target = self;
                [diskMenu addItem:i2];
                diskItem.submenu = diskMenu;
                [menu addItem:diskItem];
            } else {
                // Unmounted: direct click to mount (no submenu)
                NSMenuItem *diskItem = [[NSMenuItem alloc] initWithTitle:title action:@selector(mountDisk:) keyEquivalent:@""];
                if (diskIcon) diskItem.image = diskIcon;
                diskItem.representedObject = @{@"host": h.name, @"disk": d.letter};
                diskItem.target = self;
                [menu addItem:diskItem];
            }
        }

        [menu addItem:[NSMenuItem separatorItem]];

        // Host actions
        if (mc < (NSInteger)h.disks.count) {
            NSMenuItem *m = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"   Connect All %@ Disks", h.name]
                action:@selector(mountAllForHost:) keyEquivalent:@""];
            m.representedObject = h.name; m.target = self; [menu addItem:m];
        }
        if (mc > 0 || hasStale) {
            NSMenuItem *m = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"   Disconnect All %@ Disks", h.name]
                action:@selector(unmountAllForHost:) keyEquivalent:@""];
            m.representedObject = h.name; m.target = self; [menu addItem:m];
        }
        if (hasStale) {
            NSMenuItem *m = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"   Reconnect %@ Broken", h.name]
                action:@selector(healAllForHost:) keyEquivalent:@""];
            m.representedObject = h.name; m.target = self; [menu addItem:m];
        }

        // Wake-on-LAN
        if (h.macAddress.length > 0) {
            NSMenuItem *w = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"   Wake Up %@", h.name]
                action:@selector(wakeHost:) keyEquivalent:@""];
            w.image = [self sfSymbol:@"bolt.fill" size:12 color:nil];
            w.representedObject = h.name; w.target = self; [menu addItem:w];
        }

        // Edit / Remove
        NSMenuItem *e = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"   Edit %@...", h.name]
            action:@selector(showEditWorkstationDialog:) keyEquivalent:@""];
        e.representedObject = h.name; e.target = self; [menu addItem:e];

        NSMenuItem *r = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"   Remove %@", h.name]
            action:@selector(removeWorkstation:) keyEquivalent:@""];
        r.representedObject = h.name; r.target = self; [menu addItem:r];

        [menu addItem:[NSMenuItem separatorItem]];
    }

    // Global actions
    NSMenuItem *addWS = [[NSMenuItem alloc] initWithTitle:@"Add Computer..." action:@selector(showAddWorkstationDialog:) keyEquivalent:@"n"];
    addWS.image = [self sfSymbol:@"plus.circle" size:12 color:nil];
    addWS.target = self; [menu addItem:addWS];

    NSMenuItem *setupGuide = [[NSMenuItem alloc] initWithTitle:@"Setup Guide..." action:@selector(showSetupWizard:) keyEquivalent:@""];
    setupGuide.image = [self sfSymbol:@"wand.and.stars" size:12 color:nil];
    setupGuide.target = self; [menu addItem:setupGuide];

    NSMenuItem *healAll = [[NSMenuItem alloc] initWithTitle:@"Fix All Broken Connections" action:@selector(healAllStale:) keyEquivalent:@"h"];
    healAll.target = self; [menu addItem:healAll];

    NSMenuItem *bwToggle = [[NSMenuItem alloc] initWithTitle:@"Show Connection Speed"
        action:@selector(toggleLatency:) keyEquivalent:@""];
    bwToggle.state = self.showLatency ? NSControlStateValueOn : NSControlStateValueOff;
    bwToggle.target = self;
    [menu addItem:bwToggle];

    NSMenuItem *ref = [[NSMenuItem alloc] initWithTitle:@"Refresh" action:@selector(doRefresh:) keyEquivalent:@"r"];
    ref.image = [self sfSymbol:@"arrow.clockwise" size:12 color:nil];
    ref.target = self; [menu addItem:ref];

    NSMenuItem *prefs = [[NSMenuItem alloc] initWithTitle:@"Preferences..." action:@selector(showPreferences:) keyEquivalent:@","];
    prefs.image = [self sfSymbol:@"gearshape" size:12 color:nil];
    prefs.target = self; [menu addItem:prefs];

    NSString *claudeTitle = [self isMCPInstalled] ? @"Claude Integration ✓" : @"Enable Claude Integration...";
    NSMenuItem *claude = [[NSMenuItem alloc] initWithTitle:claudeTitle action:@selector(showClaudeIntegration:) keyEquivalent:@""];
    claude.image = [self sfSymbol:@"sparkles" size:12 color:nil];
    claude.target = self; [menu addItem:claude];

#if SPARKLE_AVAILABLE
    NSMenuItem *checkUpdates = [[NSMenuItem alloc] initWithTitle:@"Check for Updates..." action:@selector(checkForUpdates:) keyEquivalent:@""];
    checkUpdates.target = self.updaterController;
    [menu addItem:checkUpdates];
#endif

    [menu addItem:[NSMenuItem separatorItem]];

    // Start at Login toggle
    NSMenuItem *loginItem = [[NSMenuItem alloc] initWithTitle:@"Start at Login" action:@selector(toggleStartAtLogin:) keyEquivalent:@""];
    loginItem.target = self;
    loginItem.state = self.startsAtLogin ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:loginItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *q = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    q.target = NSApp; [menu addItem:q];

    self.statusItem.menu = menu;
}

// ─── VPN Detection ─────────────────────────────────────────────────────────

- (void)refreshVPNStatus {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSString *result = [self runDiscover:@[@"detect-vpn"] timeout:5];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.vpnStatus = [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        });
    });
}

// ─── Config Management ──────────────────────────────────────────────────────

- (NSString *)resolveConfigPath {
    // New config path
    NSString *homeConfig = [NSHomeDirectory() stringByAppendingPathComponent:@".config/autofuse/config.json"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:homeConfig]) return homeConfig;

    // Backward compat: check old path and migrate if found
    NSString *oldConfig = [NSHomeDirectory() stringByAppendingPathComponent:@".config/workstationmount/config.json"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:oldConfig]) {
        NSString *dir = [homeConfig stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSFileManager defaultManager] copyItemAtPath:oldConfig toPath:homeConfig error:nil];
        NSDictionary *attrs = @{NSFilePosixPermissions: @(0600)};
        [[NSFileManager defaultManager] setAttributes:attrs ofItemAtPath:homeConfig error:nil];
        return homeConfig;
    }

    NSString *bundleConfig = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"config.json"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:bundleConfig]) {
        NSString *dir = [homeConfig stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSFileManager defaultManager] copyItemAtPath:bundleConfig toPath:homeConfig error:nil];
        // Set restrictive permissions on config file (#4)
        NSDictionary *attrs = @{NSFilePosixPermissions: @(0600)};
        [[NSFileManager defaultManager] setAttributes:attrs ofItemAtPath:homeConfig error:nil];
        return homeConfig;
    }
    return homeConfig;
}

- (NSMutableDictionary *)loadConfig {
    NSData *data = [NSData dataWithContentsOfFile:self.configPath];
    if (!data) return nil;
    NSError *err = nil;
    NSMutableDictionary *cfg = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&err];
    return err ? nil : cfg;
}

- (BOOL)saveConfig:(NSDictionary *)cfg {
    // Guard: a nil cfg (e.g. loadConfig returned nil on a missing/corrupt
    // config) makes +dataWithJSONObject: raise NSInvalidArgumentException and
    // crash. Refuse instead — also preserves the on-disk config (we never
    // overwrite a readable file with garbage from a failed load).
    if (!cfg) return NO;
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:cfg options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&err];
    if (err) return NO;
    BOOL ok = [data writeToFile:self.configPath atomically:YES];
    if (ok) {
        // Ensure restrictive permissions after save (#4)
        NSDictionary *attrs = @{NSFilePosixPermissions: @(0600)};
        [[NSFileManager defaultManager] setAttributes:attrs ofItemAtPath:self.configPath error:nil];
    }
    return ok;
}

// ─── Latency Toggle ────────────────────────────────────────────────────────

- (void)toggleLatency:(NSMenuItem *)sender {
    self.showLatency = !self.showLatency;
    NSMutableDictionary *cfg = [self loadConfig];
    cfg[@"show_latency"] = @(self.showLatency);
    [self saveConfig:cfg];
    [self updateIcon];
    [self buildMenu];
}

// ─── Actions ────────────────────────────────────────────────────────────────

- (void)_asyncOp:(NSString *)label block:(void(^)(void))block {
    // Atomic counter: increment on start (#6)
    @synchronized(self) {
        self.operationCount++;
    }
    [self updateIcon];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        block();
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized(self) {
                self.operationCount--;
                if (self.operationCount < 0) self.operationCount = 0;
            }
            [self refreshStatus];
            [self buildMenu];
        });
    });
}

// Translate raw mount.sh error output into user-readable explanation.
// Raw output is shaped like "failed:/path:SSH connection failed to X (key: Y)"
// or "error:host_key_mismatch:no_verified_endpoint" — technical and
// intimidating for non-developer users. This helper maps known failure
// codes to plain-English guidance on what went wrong and what to do
// next. Unknown codes fall through to the raw message so nothing is
// ever silently swallowed.
- (NSString *)humanizeErrorMessage:(NSString *)raw {
    if (raw.length == 0) return @"Unknown error.";

    // Known failure codes (order matters — check most specific first)
    if ([raw containsString:@"host_key_mismatch"]) {
        return @"Security check failed — the remote SSH host key doesn't match what AutoFuse has on file. "
               @"If you recently reinstalled the server, open Edit Workstation and click 'Re-learn Host Key'. "
               @"If not, someone may be impersonating the server — investigate before reconnecting.";
    }
    if ([raw containsString:@"probe_failed:host_unreachable"]) {
        return @"The workstation isn't answering on either SSH (port 22) or SMB (port 445). "
               @"Check that it's powered on and on the same network as your Mac.";
    }
    if ([raw containsString:@"SSH connection failed"]) {
        return @"Couldn't establish an SSH connection to the workstation. "
               @"Likely causes:\n"
               @"  • The workstation is off — try Wake Up from the menu\n"
               @"  • Your SSH key isn't authorized on the remote host\n"
               @"  • Firewall is blocking port 22\n"
               @"  • Network is slow — increase connect_timeout in config";
    }
    if ([raw containsString:@"no_config"]) {
        return @"AutoFuse configuration file is missing. Run Setup Guide from the menu to recreate it.";
    }
    if ([raw containsString:@"invalid_json"]) {
        return @"The config file (~/.config/autofuse/config.json) is corrupted. "
               @"Open it in a text editor and fix the JSON syntax, or delete it and re-run Setup.";
    }
    if ([raw containsString:@"no_mac"]) {
        return @"This workstation has no MAC address configured, so Wake-on-LAN can't be used. "
               @"Edit the workstation and fill in the MAC address to enable wake-up.";
    }
    if ([raw containsString:@"invalid_mac"]) {
        return @"The MAC address for this workstation is malformed. "
               @"Edit the workstation and enter a valid MAC (e.g. AA:BB:CC:DD:EE:FF).";
    }
    if ([raw containsString:@"sshfs_not_found"]) {
        return @"sshfs is not installed. Run:\n"
               @"  brew install macfuse\n"
               @"  brew install gromgit/fuse/sshfs-mac\n"
               @"...or install FUSE-T + sshfs from https://www.fuse-t.org";
    }
    if ([raw containsString:@"not_mounted"]) {
        return @"The disk is not currently mounted. Click it in the menu to connect first.";
    }
    if ([raw containsString:@"timeout"]) {
        return @"The operation took too long and was cancelled. "
               @"The workstation may be slow, unresponsive, or on a high-latency link. "
               @"Try again, or check network conditions.";
    }
    if ([raw containsString:@"no_verified_endpoint"]) {
        return @"None of the configured endpoints (LAN, VPN, additional IPs) passed the host-key check. "
               @"Either the workstation is unreachable, or its SSH identity has changed since you learned it.";
    }
    // Fallback: show raw but trimmed of internal paths that look noisy
    return [NSString stringWithFormat:@"The operation failed with this message:\n\n%@", raw];
}

// Async op variant that captures output and shows error on failure (#10)
- (void)_asyncOp:(NSString *)label args:(NSArray *)args timeout:(NSTimeInterval)timeout {
    @synchronized(self) {
        self.operationCount++;
    }
    [self updateIcon];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *errOutput = nil;
        NSString *result = [self runScript:args timeout:timeout error:&errOutput];
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized(self) {
                self.operationCount--;
                if (self.operationCount < 0) self.operationCount = 0;
            }
            [self refreshStatus];
            [self buildMenu];

            // Show error feedback (#10)
            BOOL hasFailed = [result containsString:@"failed:"] || [result containsString:@"error:"] || [result isEqualToString:@"timeout"];
            if (hasFailed) {
                NSString *friendly = [self humanizeErrorMessage:result];
                NSAlert *a = [NSAlert new];
                a.messageText = [NSString stringWithFormat:@"%@ Failed", [label capitalizedString]];
                a.informativeText = friendly;
                a.alertStyle = NSAlertStyleWarning;
                // Keep the raw output available for developers/troubleshooting
                // in a collapsible "Details" disclosure panel so we don't lose
                // diagnostic info when translating to user-friendly language.
                NSString *rawDetails = errOutput.length > 0
                    ? [NSString stringWithFormat:@"%@\n\nstderr:\n%@", result, errOutput]
                    : result;
                a.accessoryView = ({
                    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 420, 80)];
                    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, 80)];
                    tv.string = rawDetails;
                    tv.editable = NO;
                    tv.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
                    sv.documentView = tv;
                    sv.hasVerticalScroller = YES;
                    sv;
                });
                [a runModal];

                // Notifications are single-line; use the friendly first line only
                NSString *firstLine = [friendly componentsSeparatedByString:@"\n"].firstObject;
                [self postNotificationWithTitle:[NSString stringWithFormat:@"%@ Failed", [label capitalizedString]]
                                           body:firstLine ?: friendly];
            } else if ([result containsString:@"mounted_"]) {
                [self postNotificationWithTitle:@"Mount Successful"
                                           body:result];
            } else if ([result containsString:@"healing_stale"]) {
                [self postNotificationWithTitle:@"Auto-Heal"
                                           body:@"Stale mount detected and recovered"];
            }
        });
    });
}

- (void)mountDisk:(NSMenuItem *)sender {
    NSDictionary *info = sender.representedObject;
    [self _asyncOp:@"Mount" args:@[@"mount", info[@"host"], info[@"disk"]] timeout:90];
}

- (void)unmountDisk:(NSMenuItem *)sender {
    NSDictionary *info = sender.representedObject;
    [self _asyncOp:@"Unmount" args:@[@"unmount", info[@"host"], info[@"disk"]] timeout:30];
}

- (void)healDisk:(NSMenuItem *)sender {
    NSDictionary *info = sender.representedObject;
    [self _asyncOp:@"Heal" args:@[@"heal", info[@"host"], info[@"disk"]] timeout:90];
}

- (void)mountAllForHost:(NSMenuItem *)sender {
    NSString *h = sender.representedObject;
    [self _asyncOp:@"Mount All" args:@[@"mount", h] timeout:120];
}

- (void)unmountAllForHost:(NSMenuItem *)sender {
    NSString *h = sender.representedObject;
    [self _asyncOp:@"Unmount All" args:@[@"unmount", h] timeout:30];
}

- (void)healAllForHost:(NSMenuItem *)sender {
    NSString *h = sender.representedObject;
    [self _asyncOp:@"Heal" args:@[@"heal", h] timeout:90];
}

- (void)healAllStale:(NSMenuItem *)sender {
    [self _asyncOp:@"Heal All" args:@[@"heal-all"] timeout:120];
}

- (void)wakeHost:(NSMenuItem *)sender {
    NSString *h = sender.representedObject;
    NSString *result = [self runScript:@[@"wol", h]];
    NSAlert *a = [NSAlert new];
    if ([result containsString:@"wol_sent"]) {
        a.messageText = @"Wake-on-LAN Sent";
        a.informativeText = [NSString stringWithFormat:@"Magic packet sent to %@.\nThe machine may take 30-60 seconds to boot.", h];
        a.alertStyle = NSAlertStyleInformational;
    } else if ([result containsString:@"no_mac"]) {
        a.messageText = @"No MAC Address";
        a.informativeText = @"Add mac_address to the workstation config to use Wake-on-LAN.";
        a.alertStyle = NSAlertStyleWarning;
    } else if ([result containsString:@"invalid_mac"]) {
        a.messageText = @"Invalid MAC Address";
        a.informativeText = @"The MAC address format is invalid. Use format AA:BB:CC:DD:EE:FF.";
        a.alertStyle = NSAlertStyleWarning;
    } else {
        a.messageText = @"WoL Failed";
        a.informativeText = result;
        a.alertStyle = NSAlertStyleCritical;
    }
    [a runModal];
}

- (void)openInFinder:(NSMenuItem *)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:sender.representedObject isDirectory:YES]];
}

// Use NSTask to launch Terminal instead of AppleScript injection
- (void)openInTerminal:(NSMenuItem *)sender {
    NSString *path = sender.representedObject;
    // Use NSTask + open to safely launch Terminal with the directory
    NSTask *t = [NSTask new];
    t.launchPath = @"/usr/bin/open";
    t.arguments = @[@"-a", @"Terminal", path];
    @try {
        [t launch];
    }
    @catch (NSException *e) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"Cannot Open Terminal";
        a.informativeText = e.reason ?: @"Unknown error";
        a.alertStyle = NSAlertStyleWarning;
        [a runModal];
    }
}

- (void)doRefresh:(NSMenuItem *)sender {
    [self loadHosts]; [self refreshStatus]; [self buildMenu];
}

// ─── Start at Login ────────────────────────────────────────────────────────

- (void)toggleStartAtLogin:(NSMenuItem *)sender {
    if (self.startsAtLogin) {
        NSError *err = nil;
        [SMAppService.mainAppService unregisterAndReturnError:&err];
        if (err) {
            NSAlert *a = [NSAlert new];
            a.messageText = @"Could not disable login item";
            a.informativeText = err.localizedDescription;
            a.alertStyle = NSAlertStyleWarning;
            [a runModal];
            return;
        }
    } else {
        NSError *err = nil;
        [SMAppService.mainAppService registerAndReturnError:&err];
        if (err) {
            NSAlert *a = [NSAlert new];
            a.messageText = @"Could not enable login item";
            a.informativeText = err.localizedDescription;
            a.alertStyle = NSAlertStyleWarning;
            [a runModal];
            return;
        }
    }
    self.startsAtLogin = (SMAppService.mainAppService.status == SMAppServiceStatusEnabled);
    [self buildMenu];
}

// ─── Preferences Window ───────────────────────────────────────────────────

// Tab-based preferences window (SSH / Cache / Connection / Advanced).
// Held as an instance property so re-opening returns the existing window
// instead of rebuilding — preserves unsaved edits if the user clicks away
// and back. Reads values from `~/.config/autofuse/config.json` top-level
// objects (`ssh_options`, `cache_options`, `io_options`, `connection_opts`)
// and writes them back via `saveConfig:` which uses the same atomic
// tmpfile+fsync+replace pattern as `learn-host-key` to survive crashes.
// Cmd+, opens this window (standard macOS shortcut) via the app's main menu.
- (void)showPreferences:(NSMenuItem *)sender {
    if (self.preferencesWindow && self.preferencesWindow.isVisible) {
        [self.preferencesWindow makeKeyAndOrderFront:nil];
        return;
    }
    [NSApp activateIgnoringOtherApps:YES];

    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 480, 400)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    win.title = @"AutoFuse Preferences";
    [win center];
    win.level = NSFloatingWindowLevel;
    win.delegate = self;
    win.releasedWhenClosed = NO;  // ARC: red-X close must not dealloc the window (crash on reopen)

    // Load current config
    NSMutableDictionary *cfg = [self loadConfig];
    NSDictionary *sshOpts = cfg[@"ssh_options"] ?: @{};
    NSDictionary *cacheOpts = cfg[@"cache_options"] ?: @{};
    NSDictionary *ioOpts = cfg[@"io_options"] ?: @{};

    // Tab view
    NSTabView *tabView = [[NSTabView alloc] initWithFrame:NSMakeRect(10, 50, 460, 340)];

    // ── General Tab ──
    NSTabViewItem *generalTab = [[NSTabViewItem alloc] initWithIdentifier:@"general"];
    generalTab.label = @"General";
    NSView *gv = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 280)];

    CGFloat gy = 240;

    // Start at Login checkbox
    NSButton *loginCheck = [[NSButton alloc] initWithFrame:NSMakeRect(20, gy, 300, 20)];
    loginCheck.buttonType = NSButtonTypeSwitch;
    loginCheck.title = @"Start at Login";
    loginCheck.state = self.startsAtLogin ? NSControlStateValueOn : NSControlStateValueOff;
    loginCheck.target = self;
    loginCheck.action = @selector(prefLoginToggled:);
    [gv addSubview:loginCheck]; gy -= 36;

    // Polling Interval
    [gv addSubview:[self makeLabel:@"Polling Interval (sec):" frame:NSMakeRect(20, gy, 180, 20)]];
    NSStepper *pollStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(340, gy, 20, 20)];
    pollStepper.minValue = 10; pollStepper.maxValue = 120; pollStepper.increment = 5;
    NSInteger pollVal = [cfg[@"poll_interval"] integerValue];
    if (pollVal < 10) pollVal = 30;
    pollStepper.integerValue = pollVal;
    NSTextField *pollField = [[NSTextField alloc] initWithFrame:NSMakeRect(260, gy, 70, 20)];
    pollField.integerValue = pollVal; pollField.editable = NO;
    pollField.tag = 1001;
    pollStepper.tag = 2001;
    pollStepper.target = self; pollStepper.action = @selector(prefStepperChanged:);
    [gv addSubview:pollField]; [gv addSubview:pollStepper]; gy -= 36;

    // Auto-Heal Interval
    [gv addSubview:[self makeLabel:@"Auto-Heal Interval (sec):" frame:NSMakeRect(20, gy, 200, 20)]];
    NSStepper *healStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(340, gy, 20, 20)];
    healStepper.minValue = 30; healStepper.maxValue = 600; healStepper.increment = 10;
    NSInteger healVal = [cfg[@"heal_interval"] integerValue];
    if (healVal < 30) healVal = 120;
    healStepper.integerValue = healVal;
    NSTextField *healField = [[NSTextField alloc] initWithFrame:NSMakeRect(260, gy, 70, 20)];
    healField.integerValue = healVal; healField.editable = NO;
    healField.tag = 1002;
    healStepper.tag = 2002;
    healStepper.target = self; healStepper.action = @selector(prefStepperChanged:);
    [gv addSubview:healField]; [gv addSubview:healStepper]; gy -= 36;

    // Auto-Heal on Network Change
    NSButton *healNetCheck = [[NSButton alloc] initWithFrame:NSMakeRect(20, gy, 300, 20)];
    healNetCheck.buttonType = NSButtonTypeSwitch;
    healNetCheck.title = @"Auto-Heal on Network Change";
    BOOL healOnNet = cfg[@"heal_on_network_change"] ? [cfg[@"heal_on_network_change"] boolValue] : YES;
    healNetCheck.state = healOnNet ? NSControlStateValueOn : NSControlStateValueOff;
    healNetCheck.tag = 3001;
    healNetCheck.target = self; healNetCheck.action = @selector(prefCheckboxChanged:);
    [gv addSubview:healNetCheck]; gy -= 36;

    // Mount Base Directory
    [gv addSubview:[self makeLabel:@"Mount Base Directory:" frame:NSMakeRect(20, gy, 180, 20)]];
    NSTextField *mountBaseField = [[NSTextField alloc] initWithFrame:NSMakeRect(200, gy, 220, 20)];
    mountBaseField.stringValue = cfg[@"mount_base"] ?: @"~/workstation";
    mountBaseField.font = [NSFont systemFontOfSize:12];
    mountBaseField.tag = 4001;
    mountBaseField.target = self; mountBaseField.action = @selector(prefTextFieldChanged:);
    [gv addSubview:mountBaseField];

    generalTab.view = gv;
    [tabView addTabViewItem:generalTab];

    // ── SSH Tab ──
    NSTabViewItem *sshTab = [[NSTabViewItem alloc] initWithIdentifier:@"ssh"];
    sshTab.label = @"SSH";
    NSView *sv = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 280)];
    CGFloat sy = 240;

    // Cipher dropdown
    [sv addSubview:[self makeLabel:@"Cipher:" frame:NSMakeRect(20, sy, 120, 20)]];
    NSPopUpButton *cipherPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(160, sy, 260, 24) pullsDown:NO];
    [cipherPopup addItemWithTitle:@"aes128-gcm@openssh.com"];
    [cipherPopup addItemWithTitle:@"aes256-gcm@openssh.com"];
    [cipherPopup addItemWithTitle:@"chacha20-poly1305@openssh.com"];
    NSString *currentCipher = sshOpts[@"cipher"] ?: @"aes128-gcm@openssh.com";
    [cipherPopup selectItemWithTitle:currentCipher];
    cipherPopup.tag = 5001;
    cipherPopup.target = self; cipherPopup.action = @selector(prefPopupChanged:);
    [sv addSubview:cipherPopup]; sy -= 40;

    // Compression checkbox
    NSButton *compCheck = [[NSButton alloc] initWithFrame:NSMakeRect(20, sy, 300, 20)];
    compCheck.buttonType = NSButtonTypeSwitch;
    compCheck.title = @"Compression";
    compCheck.state = [sshOpts[@"compression"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    compCheck.tag = 3002;
    compCheck.target = self; compCheck.action = @selector(prefCheckboxChanged:);
    [sv addSubview:compCheck]; sy -= 40;

    // Keep-Alive Interval
    [sv addSubview:[self makeLabel:@"Keep-Alive Interval (sec):" frame:NSMakeRect(20, sy, 200, 20)]];
    NSStepper *kaStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(340, sy, 20, 20)];
    kaStepper.minValue = 5; kaStepper.maxValue = 60; kaStepper.increment = 5;
    NSInteger kaVal = [sshOpts[@"keepalive_interval"] integerValue];
    if (kaVal < 5) kaVal = 15;
    kaStepper.integerValue = kaVal;
    NSTextField *kaField = [[NSTextField alloc] initWithFrame:NSMakeRect(260, sy, 70, 20)];
    kaField.integerValue = kaVal; kaField.editable = NO;
    kaField.tag = 1003;
    kaStepper.tag = 2003;
    kaStepper.target = self; kaStepper.action = @selector(prefStepperChanged:);
    [sv addSubview:kaField]; [sv addSubview:kaStepper];

    sshTab.view = sv;
    [tabView addTabViewItem:sshTab];

    // ── Cache Tab ──
    NSTabViewItem *cacheTab = [[NSTabViewItem alloc] initWithIdentifier:@"cache"];
    cacheTab.label = @"Cache";
    NSView *cv = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 280)];
    CGFloat cy = 240;

    // Cache Timeout (hours)
    [cv addSubview:[self makeLabel:@"Cache Timeout (hours):" frame:NSMakeRect(20, cy, 180, 20)]];
    NSStepper *cacheStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(340, cy, 20, 20)];
    cacheStepper.minValue = 1; cacheStepper.maxValue = 72; cacheStepper.increment = 1;
    NSInteger cacheSeconds = [cacheOpts[@"cache_timeout"] integerValue];
    NSInteger cacheHours = cacheSeconds > 0 ? cacheSeconds / 3600 : 32;
    if (cacheHours < 1) cacheHours = 32;
    cacheStepper.integerValue = cacheHours;
    NSTextField *cacheField = [[NSTextField alloc] initWithFrame:NSMakeRect(260, cy, 70, 20)];
    cacheField.integerValue = cacheHours; cacheField.editable = NO;
    cacheField.tag = 1004;
    cacheStepper.tag = 2004;
    cacheStepper.target = self; cacheStepper.action = @selector(prefStepperChanged:);
    [cv addSubview:cacheField]; [cv addSubview:cacheStepper]; cy -= 40;

    // Kernel Cache
    NSButton *kernelCheck = [[NSButton alloc] initWithFrame:NSMakeRect(20, cy, 300, 20)];
    kernelCheck.buttonType = NSButtonTypeSwitch;
    kernelCheck.title = @"Kernel Cache";
    BOOL kernelVal = cacheOpts[@"kernel_cache"] ? [cacheOpts[@"kernel_cache"] boolValue] : YES;
    kernelCheck.state = kernelVal ? NSControlStateValueOn : NSControlStateValueOff;
    kernelCheck.tag = 3003;
    kernelCheck.target = self; kernelCheck.action = @selector(prefCheckboxChanged:);
    [cv addSubview:kernelCheck]; cy -= 40;

    // IO Block Size dropdown
    [cv addSubview:[self makeLabel:@"IO Block Size:" frame:NSMakeRect(20, cy, 120, 20)]];
    NSPopUpButton *ioPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(160, cy, 200, 24) pullsDown:NO];
    [ioPopup addItemWithTitle:@"256KB"];
    [ioPopup addItemWithTitle:@"512KB"];
    [ioPopup addItemWithTitle:@"1MB"];
    [ioPopup addItemWithTitle:@"2MB"];
    NSInteger ioSize = [ioOpts[@"iosize"] integerValue];
    if (ioSize <= 262144) [ioPopup selectItemWithTitle:@"256KB"];
    else if (ioSize <= 524288) [ioPopup selectItemWithTitle:@"512KB"];
    else if (ioSize <= 1048576) [ioPopup selectItemWithTitle:@"1MB"];
    else [ioPopup selectItemWithTitle:@"2MB"];
    ioPopup.tag = 5002;
    ioPopup.target = self; ioPopup.action = @selector(prefPopupChanged:);
    [cv addSubview:ioPopup];

    cacheTab.view = cv;
    [tabView addTabViewItem:cacheTab];

    [win.contentView addSubview:tabView];

    // Store tab view reference for preference actions
    objc_setAssociatedObject(win, &kFieldsKey, @{
        @"tabView": tabView
    }, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    self.preferencesWindow = win;
    [win makeKeyAndOrderFront:nil];
}

// ─── Preference Actions ───────────────────────────────────────────────────

- (void)prefLoginToggled:(NSButton *)sender {
    [self toggleStartAtLogin:nil];
    sender.state = self.startsAtLogin ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)prefStepperChanged:(NSStepper *)sender {
    // Map stepper tag to text field tag: 2001->1001, 2002->1002, etc.
    NSInteger fieldTag = sender.tag - 1000;
    NSView *container = sender.superview;
    NSTextField *field = [container viewWithTag:fieldTag];
    if (field) field.integerValue = sender.integerValue;

    [self savePreferencesFromWindow:sender.window];
}

- (void)prefCheckboxChanged:(NSButton *)sender {
    [self savePreferencesFromWindow:sender.window];
}

- (void)prefPopupChanged:(NSPopUpButton *)sender {
    [self savePreferencesFromWindow:sender.window];
}

- (void)prefTextFieldChanged:(NSTextField *)sender {
    [self savePreferencesFromWindow:sender.window];
}

- (void)savePreferencesFromWindow:(NSWindow *)win {
    NSMutableDictionary *cfg = [self loadConfig];
    if (!cfg) return;

    // Find controls in tabs via the tab view
    NSDictionary *refs = objc_getAssociatedObject(win, &kFieldsKey);
    NSTabView *tabView = refs[@"tabView"];

    // General tab (index 0)
    NSView *gv = [tabView tabViewItemAtIndex:0].view;
    NSTextField *pollField = [gv viewWithTag:1001];
    NSTextField *healField = [gv viewWithTag:1002];
    NSTextField *mountBaseField = [gv viewWithTag:4001];
    NSButton *healNetCheck = [gv viewWithTag:3001];

    if (pollField) cfg[@"poll_interval"] = @(pollField.integerValue);
    if (healField) cfg[@"heal_interval"] = @(healField.integerValue);
    if (mountBaseField) cfg[@"mount_base"] = mountBaseField.stringValue;
    if (healNetCheck) cfg[@"heal_on_network_change"] = @(healNetCheck.state == NSControlStateValueOn);

    // SSH tab (index 1)
    NSView *sv = [tabView tabViewItemAtIndex:1].view;
    NSPopUpButton *cipherPopup = [sv viewWithTag:5001];
    NSButton *compCheck = [sv viewWithTag:3002];
    NSTextField *kaField = [sv viewWithTag:1003];

    NSMutableDictionary *sshOpts = [NSMutableDictionary dictionaryWithDictionary:cfg[@"ssh_options"] ?: @{}];
    if (cipherPopup) sshOpts[@"cipher"] = cipherPopup.titleOfSelectedItem;
    if (compCheck) sshOpts[@"compression"] = @(compCheck.state == NSControlStateValueOn);
    if (kaField) sshOpts[@"keepalive_interval"] = @(kaField.integerValue);
    cfg[@"ssh_options"] = sshOpts;

    // Cache tab (index 2)
    NSView *cacheView = [tabView tabViewItemAtIndex:2].view;
    NSTextField *cacheField = [cacheView viewWithTag:1004];
    NSButton *kernelCheck = [cacheView viewWithTag:3003];
    NSPopUpButton *ioPopup = [cacheView viewWithTag:5002];

    NSMutableDictionary *cacheOpts = [NSMutableDictionary dictionaryWithDictionary:cfg[@"cache_options"] ?: @{}];
    if (cacheField) {
        NSInteger hours = cacheField.integerValue;
        NSInteger seconds = hours * 3600;
        cacheOpts[@"cache_timeout"] = @(seconds);
        cacheOpts[@"attr_timeout"] = @(seconds);
        cacheOpts[@"entry_timeout"] = @(seconds);
    }
    if (kernelCheck) cacheOpts[@"kernel_cache"] = @(kernelCheck.state == NSControlStateValueOn);
    cfg[@"cache_options"] = cacheOpts;

    NSMutableDictionary *ioOpts = [NSMutableDictionary dictionaryWithDictionary:cfg[@"io_options"] ?: @{}];
    if (ioPopup) {
        NSString *selected = ioPopup.titleOfSelectedItem;
        NSInteger ioSize = 1048576; // default 1MB
        if ([selected isEqualToString:@"256KB"]) ioSize = 262144;
        else if ([selected isEqualToString:@"512KB"]) ioSize = 524288;
        else if ([selected isEqualToString:@"1MB"]) ioSize = 1048576;
        else if ([selected isEqualToString:@"2MB"]) ioSize = 2097152;
        ioOpts[@"iosize"] = @(ioSize);
    }
    cfg[@"io_options"] = ioOpts;

    [self saveConfig:cfg];

    // Apply poll/heal interval changes live (config saved just above).
    [self applyTimerCadence:YES];
}

// ─── Add/Edit Workstation Dialog ────────────────────────────────────────────

- (NSTextField *)makeLabel:(NSString *)text frame:(NSRect)frame {
    NSTextField *lbl = [[NSTextField alloc] initWithFrame:frame];
    lbl.stringValue = text; lbl.bezeled = NO; lbl.editable = NO;
    lbl.selectable = NO; lbl.drawsBackground = NO;
    lbl.font = [NSFont systemFontOfSize:12];
    return lbl;
}

- (NSTextField *)makeField:(NSString *)placeholder frame:(NSRect)frame {
    NSTextField *fld = [[NSTextField alloc] initWithFrame:frame];
    fld.placeholderString = placeholder; fld.font = [NSFont systemFontOfSize:12];
    return fld;
}

// Create the dialog window and return it with fields populated
- (NSWindow *)_createWorkstationDialogWithTitle:(NSString *)title editMode:(NSString *)editMode {
    [NSApp activateIgnoringOtherApps:YES];

    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 520, 820)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    win.title = title;
    [win center];
    win.level = NSFloatingWindowLevel;
    win.releasedWhenClosed = NO;  // ARC: red-X close must not dealloc the window (crash on reopen)

    NSView *cv = win.contentView;
    CGFloat y = 770, lw = 140, fw = 220, h = 24, gap = 36;
    CGFloat btnW = 100;

    [cv addSubview:[self makeLabel:@"Name:" frame:NSMakeRect(20, y, lw, h)]];
    NSTextField *nameField = [self makeField:@"e.g. MyServer" frame:NSMakeRect(160, y, fw, h)];
    [cv addSubview:nameField];
    // Import from SSH button
    NSButton *importSSHBtn = [[NSButton alloc] initWithFrame:NSMakeRect(390, y, 110, h)];
    importSSHBtn.title = @"Import SSH..."; importSSHBtn.bezelStyle = NSBezelStyleRounded;
    importSSHBtn.font = [NSFont systemFontOfSize:11];
    importSSHBtn.target = self; importSSHBtn.action = @selector(discoverImportSSH:);
    [cv addSubview:importSSHBtn]; y -= gap;

    [cv addSubview:[self makeLabel:@"SSH User:" frame:NSMakeRect(20, y, lw, h)]];
    NSTextField *userField = [self makeField:@"e.g. admin" frame:NSMakeRect(160, y, fw + btnW + 10, h)];
    [cv addSubview:userField]; y -= gap;

    [cv addSubview:[self makeLabel:@"LAN IP:" frame:NSMakeRect(20, y, lw, h)]];
    NSTextField *lanField = [self makeField:@"e.g. 192.168.1.100" frame:NSMakeRect(160, y, fw, h)];
    [cv addSubview:lanField];
    // Scan Network button
    NSButton *scanBtn = [[NSButton alloc] initWithFrame:NSMakeRect(390, y, 110, h)];
    scanBtn.title = @"Scan Network..."; scanBtn.bezelStyle = NSBezelStyleRounded;
    scanBtn.font = [NSFont systemFontOfSize:11];
    scanBtn.target = self; scanBtn.action = @selector(discoverScanNetwork:);
    [cv addSubview:scanBtn]; y -= gap;

    [cv addSubview:[self makeLabel:@"VPN IP (optional):" frame:NSMakeRect(20, y, lw, h)]];
    NSTextField *vpnField = [self makeField:@"e.g. 172.16.0.100" frame:NSMakeRect(160, y, fw + btnW + 10, h)];
    [cv addSubview:vpnField]; y -= gap;

    [cv addSubview:[self makeLabel:@"SSH Key:" frame:NSMakeRect(20, y, lw, h)]];
    NSTextField *keyField = [self makeField:@"~/.ssh/id_ed25519" frame:NSMakeRect(160, y, fw + btnW + 10, h)];
    keyField.stringValue = @"~/.ssh/id_ed25519";
    [cv addSubview:keyField]; y -= gap;

    [cv addSubview:[self makeLabel:@"Protocol:" frame:NSMakeRect(20, y, lw, h)]];
    NSPopUpButton *protocolPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(160, y, fw, h)];
    [protocolPopup addItemsWithTitles:@[@"sshfs", @"smb"]];
    protocolPopup.target = self; protocolPopup.action = @selector(protocolChanged:);
    [cv addSubview:protocolPopup]; y -= gap;

    [cv addSubview:[self makeLabel:@"SMB Share:" frame:NSMakeRect(20, y, lw, h)]];
    NSTextField *smbShareField = [self makeField:@"//192.168.1.100/Share" frame:NSMakeRect(160, y, fw + btnW + 10, h)];
    smbShareField.hidden = YES;
    [cv addSubview:smbShareField]; y -= gap;

    [cv addSubview:[self makeLabel:@"MAC Address (WoL):" frame:NSMakeRect(20, y, lw, h)]];
    NSTextField *macField = [self makeField:@"e.g. AA:BB:CC:DD:EE:FF" frame:NSMakeRect(160, y, fw + btnW + 10, h)];
    [cv addSubview:macField]; y -= gap;

    // Additional IPs (multi-line, one per line)
    [cv addSubview:[self makeLabel:@"Additional IPs:" frame:NSMakeRect(20, y, lw, h)]];
    NSTextField *ipsHelp = [self makeLabel:@"One per line (Tailscale, mDNS, etc.) — extra candidates for key-verified endpoint picking"
                                     frame:NSMakeRect(160, y + 2, fw + btnW + 10, 18)];
    ipsHelp.font = [NSFont systemFontOfSize:10]; ipsHelp.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:ipsHelp]; y -= 22;
    NSScrollView *ipsScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(160, y - 44, fw + btnW + 10, 52)];
    ipsScroll.hasVerticalScroller = YES; ipsScroll.borderType = NSBezelBorder;
    NSTextView *ipsText = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, fw + btnW + 10, 52)];
    ipsText.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    ipsText.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    ipsScroll.documentView = ipsText;
    [cv addSubview:ipsScroll]; y -= 56;

    // Host key fingerprint (read-only) + Re-learn button
    [cv addSubview:[self makeLabel:@"Host Key:" frame:NSMakeRect(20, y, lw, h)]];
    NSTextField *hostKeyField = [self makeField:@"(not learned — auto-captured on first successful mount)"
                                          frame:NSMakeRect(160, y, fw, h)];
    hostKeyField.editable = NO;
    hostKeyField.selectable = YES;
    hostKeyField.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    [cv addSubview:hostKeyField];
    NSButton *relearnBtn = [[NSButton alloc] initWithFrame:NSMakeRect(390, y, 110, h)];
    relearnBtn.title = @"Re-learn"; relearnBtn.bezelStyle = NSBezelStyleRounded;
    relearnBtn.font = [NSFont systemFontOfSize:11];
    relearnBtn.target = self; relearnBtn.action = @selector(relearnHostKey:);
    [cv addSubview:relearnBtn]; y -= gap;

    NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(20, y + 10, 480, 1)];
    sep.boxType = NSBoxSeparator; [cv addSubview:sep]; y -= 10;

    [cv addSubview:[self makeLabel:@"Disks (one per line):" frame:NSMakeRect(20, y, 200, h)]]; y -= 28;

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, y - 80, 480, 110)];
    sv.hasVerticalScroller = YES; sv.borderType = NSBezelBorder;
    NSTextView *disksText = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 480, 110)];
    disksText.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    disksText.string = @"C, System, /C:/\nD, Data, /D:/";
    disksText.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    sv.documentView = disksText; [cv addSubview:sv]; y -= 120;

    NSTextField *help = [self makeLabel:@"Format: letter, label, remote_path" frame:NSMakeRect(20, y, 300, 16)];
    help.font = [NSFont systemFontOfSize:10]; help.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:help];

    // Auto-Detect button (probes host for MAC + disks)
    NSButton *autoDetectBtn = [[NSButton alloc] initWithFrame:NSMakeRect(350, y - 4, 150, 24)];
    autoDetectBtn.title = @"Auto-Detect MAC+Disks"; autoDetectBtn.bezelStyle = NSBezelStyleRounded;
    autoDetectBtn.font = [NSFont systemFontOfSize:11];
    autoDetectBtn.target = self; autoDetectBtn.action = @selector(discoverAutoDetect:);
    [cv addSubview:autoDetectBtn];

    // Buttons row
    NSButton *testBtn = [[NSButton alloc] initWithFrame:NSMakeRect(20, 16, 140, 32)];
    testBtn.title = @"Test Connection"; testBtn.bezelStyle = NSBezelStyleRounded;
    testBtn.target = self; testBtn.action = @selector(testConnection:); [cv addSubview:testBtn];

    NSButton *cancelBtn = [[NSButton alloc] initWithFrame:NSMakeRect(330, 16, 80, 32)];
    cancelBtn.title = @"Cancel"; cancelBtn.bezelStyle = NSBezelStyleRounded;
    cancelBtn.target = self; cancelBtn.action = @selector(dialogCancel:); [cv addSubview:cancelBtn];

    NSButton *saveBtn = [[NSButton alloc] initWithFrame:NSMakeRect(420, 16, 80, 32)];
    saveBtn.title = @"Save"; saveBtn.bezelStyle = NSBezelStyleRounded;
    saveBtn.keyEquivalent = @"\r"; saveBtn.target = self; saveBtn.action = @selector(saveWorkstation:);
    [cv addSubview:saveBtn];

    NSDictionary *fields = @{
        @"name": nameField, @"user": userField, @"lan": lanField,
        @"vpn": vpnField, @"key": keyField, @"mac": macField,
        @"disks": disksText, @"window": win, @"protocol": protocolPopup,
        @"smbShare": smbShareField,
        @"additionalIps": ipsText, @"hostKey": hostKeyField
    };

    // Use proper associated objects with typed keys (#14)
    objc_setAssociatedObject(win, &kEditModeKey, editMode, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(win, &kFieldsKey, fields, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(saveBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(testBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(scanBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(importSSHBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(autoDetectBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(relearnBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);

    return win;
}

- (void)protocolChanged:(NSPopUpButton *)sender {
    NSWindow *win = nil;
    NSView *current = sender;
    while (current) {
        if ([current isKindOfClass:[NSWindow class]]) {
            win = (NSWindow *)current; break;
        }
        current = [current superview];
    }
    if (!win) return;
    
    NSDictionary *fields = objc_getAssociatedObject(win, &kFieldsKey);
    NSTextField *smbShareField = fields[@"smbShare"];
    NSString *protocol = [sender titleOfSelectedItem];
    smbShareField.hidden = ![protocol isEqualToString:@"smb"];
}

// Entry point for the Add Workstation flow. The actual dialog build is in
// `_createWorkstationDialogWithTitle:editMode:` (shared with Edit — both
// flows use the same layout, same fields, same Save button; they only
// differ in the associated `kEditModeKey` value that `saveWorkstation:`
// reads to decide between append-new and update-existing). Uses `__add__`
// as a sentinel edit-mode because a real workstation could theoretically
// be named "add" (unlikely but cheap to defend against).
- (void)showAddWorkstationDialog:(id)sender {
    NSWindow *win = [self _createWorkstationDialogWithTitle:@"Add Workstation" editMode:@"__add__"];
    [win makeKeyAndOrderFront:nil];
}

- (void)dialogCancel:(NSButton *)sender { [sender.window close]; }

- (void)testConnection:(NSButton *)sender {
    NSWindow *win = objc_getAssociatedObject(sender, &kWindowKey);
    NSDictionary *fields = objc_getAssociatedObject(win, &kFieldsKey);
    NSString *user = [fields[@"user"] stringValue];
    NSString *lanIP = [fields[@"lan"] stringValue];
    NSString *key = [fields[@"key"] stringValue];
    if (user.length == 0 || lanIP.length == 0) {
        NSAlert *a = [NSAlert new]; a.messageText = @"Missing Fields";
        a.informativeText = @"Fill in SSH User and LAN IP first."; [a runModal]; return;
    }
    NSString *expandedKey = [key stringByReplacingOccurrencesOfString:@"~" withString:NSHomeDirectory()];
    NSString *knownHosts = [NSHomeDirectory() stringByAppendingPathComponent:@".config/autofuse/known_hosts"];
    NSTask *t = [NSTask new];
    t.launchPath = @"/usr/bin/ssh";
    // Use accept-new with dedicated known_hosts
    t.arguments = @[@"-o", @"ConnectTimeout=5",
                    @"-o", @"StrictHostKeyChecking=accept-new",
                    @"-o", [NSString stringWithFormat:@"UserKnownHostsFile=%@", knownHosts],
                    @"-i", expandedKey,
                    [NSString stringWithFormat:@"%@@%@", user, lanIP], @"echo ok"];
    NSPipe *p = [NSPipe pipe]; t.standardOutput = p; t.standardError = [NSPipe pipe];
    NSAlert *a = [NSAlert new];
    @try {
        [t launch]; [t waitUntilExit];
        NSString *out = [[NSString alloc] initWithData:[p.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
        if (t.terminationStatus == 0 && [out containsString:@"ok"]) {
            a.messageText = @"Connection OK"; a.informativeText = [NSString stringWithFormat:@"SSH to %@@%@ works.", user, lanIP];
            a.alertStyle = NSAlertStyleInformational;
        } else {
            a.messageText = @"Connection Failed"; a.informativeText = [NSString stringWithFormat:@"Cannot SSH to %@@%@", user, lanIP];
            a.alertStyle = NSAlertStyleWarning;
        }
    } @catch (NSException *e) { a.messageText = @"Error"; a.informativeText = e.reason; a.alertStyle = NSAlertStyleCritical; }
    [a runModal];
}

- (void)saveWorkstation:(NSButton *)sender {
    NSWindow *win = objc_getAssociatedObject(sender, &kWindowKey);
    NSDictionary *fields = objc_getAssociatedObject(win, &kFieldsKey);
    NSString *name = [fields[@"name"] stringValue], *user = [fields[@"user"] stringValue];
    NSString *lanIP = [fields[@"lan"] stringValue], *vpnIP = [fields[@"vpn"] stringValue];
    NSString *key = [fields[@"key"] stringValue], *mac = [fields[@"mac"] stringValue];
    NSString *disksRaw = [fields[@"disks"] string];
    NSPopUpButton *protocolBtn = fields[@"protocol"];
    NSString *protocol = [protocolBtn titleOfSelectedItem];
    NSString *smbShare = [fields[@"smbShare"] stringValue];

    if (name.length == 0 || user.length == 0 || (lanIP.length == 0 && vpnIP.length == 0)) {
        NSAlert *a = [NSAlert new]; a.messageText = @"Missing Fields";
        a.informativeText = @"Name, SSH User, and at least one IP required."; [a runModal]; return;
    }
    
    if ([protocol isEqualToString:@"smb"] && smbShare.length == 0) {
        NSAlert *a = [NSAlert new]; a.messageText = @"Missing SMB Share";
        a.informativeText = @"SMB protocol requires SMB Share path (e.g., //192.168.1.100/ShareName)."; [a runModal]; return;
    }

    NSMutableArray *disksArray = [NSMutableArray new];

    // Load original workstation if editing to preserve primary flags (#5, #6)
    NSDictionary *originalWorkstation = nil;
    NSMutableDictionary *originalDisksByLetter = [NSMutableDictionary new];
    NSString *editMode = objc_getAssociatedObject(win, &kEditModeKey);
    if (![editMode isEqualToString:@"__add__"] && editMode.length > 0) {
        NSMutableDictionary *cfg = [self loadConfig];
        for (NSDictionary *ws in cfg[@"workstations"]) {
            if ([ws[@"name"] isEqualToString:editMode]) {
                originalWorkstation = ws;
                for (NSDictionary *disk in ws[@"disks"]) {
                    originalDisksByLetter[disk[@"letter"]] = disk;
                }
                break;
            }
        }
    }

    for (NSString *line in [disksRaw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0) continue;
        NSArray *parts = [trimmed componentsSeparatedByString:@","]; if (parts.count < 3) continue;
        NSString *letter = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *label = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *rpath = [parts[2] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        // Preserve primary flag if it existed in original workstation
        NSMutableDictionary *diskDict = [NSMutableDictionary dictionaryWithDictionary:@{@"letter": letter, @"label": label, @"remote_path": rpath}];
        NSDictionary *originalDisk = originalDisksByLetter[letter];
        if (originalDisk && [originalDisk[@"primary"] boolValue]) {
            diskDict[@"primary"] = @YES;
        }
        [disksArray addObject:diskDict];
    }
    if (disksArray.count == 0) {
        NSAlert *a = [NSAlert new]; a.messageText = @"No Disks";
        a.informativeText = @"Add at least one disk."; [a runModal]; return;
    }

    NSMutableDictionary *ws = [NSMutableDictionary dictionaryWithDictionary:@{
        @"name": name, @"user": user, @"lan_ip": lanIP, @"vpn_ip": vpnIP,
        @"ssh_key": key, @"disks": disksArray, @"protocol": protocol
    }];
    if (mac.length > 0) ws[@"mac_address"] = mac;
    if (smbShare.length > 0) ws[@"smb_share"] = smbShare;

    // persist additional_ips from the multi-line text field.
    // One IP/hostname per line; empty lines and whitespace ignored.
    NSTextView *ipsText = fields[@"additionalIps"];
    NSString *ipsRaw = [ipsText string];
    NSMutableArray *additionalIps = [NSMutableArray new];
    for (NSString *line in [ipsRaw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length > 0) [additionalIps addObject:trimmed];
    }
    if (additionalIps.count > 0) ws[@"additional_ips"] = additionalIps;

    // Preserve host_key_sha256 from the original workstation — it's set via
    // the Re-learn button or TOFU auto-learn, never edited directly in the
    // dialog. Without this pass-through it would be silently dropped on
    // every Save.
    if (originalWorkstation) {
        id storedKey = originalWorkstation[@"host_key_sha256"];
        if (storedKey && !ws[@"host_key_sha256"]) ws[@"host_key_sha256"] = storedKey;
    }

    NSMutableDictionary *cfg = [self loadConfig];
    if (!cfg) {
        cfg = [NSMutableDictionary dictionaryWithDictionary:@{
            @"workstations": [NSMutableArray new], @"mount_base": @"~/workstation",
            @"ssh_options": @{@"cipher": @"aes128-gcm@openssh.com", @"compression": @NO, @"keepalive_interval": @15, @"keepalive_count": @3},
            @"cache_options": @{@"cache_timeout": @115200, @"attr_timeout": @115200, @"entry_timeout": @115200, @"kernel_cache": @YES, @"auto_cache": @YES},
            @"io_options": @{@"iosize": @1048576, @"max_write": @65536, @"noappledouble": @YES, @"noapplexattr": @YES, @"defer_permissions": @YES}
        }];
    }

    // Use proper associated object for edit mode (#14)
    NSMutableArray *workstations = cfg[@"workstations"];
    if ([editMode isEqualToString:@"__add__"]) {
        for (NSDictionary *existing in workstations) {
            if ([existing[@"name"] isEqualToString:name]) {
                NSAlert *a = [NSAlert new]; a.messageText = @"Duplicate Name";
                a.informativeText = [NSString stringWithFormat:@"'%@' already exists.", name]; [a runModal]; return;
            }
        }
        [workstations addObject:ws];
    } else {
        for (NSUInteger i = 0; i < workstations.count; i++) {
            if ([workstations[i][@"name"] isEqualToString:editMode]) { workstations[i] = ws; break; }
        }
    }

    if ([self saveConfig:cfg]) {
        [win close]; [self loadHosts]; [self refreshStatus]; [self buildMenu];
    } else {
        NSAlert *a = [NSAlert new]; a.messageText = @"Save Failed";
        a.informativeText = [NSString stringWithFormat:@"Could not write to %@", self.configPath]; [a runModal];
    }
}

// Store window reference directly instead of dispatch_after hack
- (void)showEditWorkstationDialog:(NSMenuItem *)sender {
    NSString *hostName = sender.representedObject;
    NSMutableDictionary *cfg = [self loadConfig];
    NSDictionary *wsData = nil;
    for (NSDictionary *w in cfg[@"workstations"])
        if ([w[@"name"] isEqualToString:hostName]) { wsData = w; break; }
    if (!wsData) return;

    NSString *title = [NSString stringWithFormat:@"Edit — %@", hostName];
    NSWindow *win = [self _createWorkstationDialogWithTitle:title editMode:hostName];

    // Populate fields directly — no fragile dispatch_after (#15)
    NSDictionary *fields = objc_getAssociatedObject(win, &kFieldsKey);
    [fields[@"name"] setStringValue:wsData[@"name"] ?: @""];
    [fields[@"user"] setStringValue:wsData[@"user"] ?: @""];
    [fields[@"lan"] setStringValue:wsData[@"lan_ip"] ?: @""];
    [fields[@"vpn"] setStringValue:wsData[@"vpn_ip"] ?: @""];
    [fields[@"key"] setStringValue:wsData[@"ssh_key"] ?: @"~/.ssh/id_ed25519"];
    [fields[@"mac"] setStringValue:wsData[@"mac_address"] ?: @""];
    
    NSString *protocol = wsData[@"protocol"] ?: @"sshfs";
    NSPopUpButton *protocolBtn = fields[@"protocol"];
    [protocolBtn selectItemWithTitle:protocol];
    
    NSTextField *smbShareField = fields[@"smbShare"];
    [smbShareField setStringValue:wsData[@"smb_share"] ?: @""];
    smbShareField.hidden = ![protocol isEqualToString:@"smb"];
    
    NSMutableString *ds = [NSMutableString new];
    for (NSDictionary *d in wsData[@"disks"])
        [ds appendFormat:@"%@, %@, %@\n", d[@"letter"], d[@"label"] ?: @"", d[@"remote_path"]];
    [fields[@"disks"] setString:ds];

    // populate additional_ips + host_key_sha256
    NSArray *extras = wsData[@"additional_ips"];
    if ([extras isKindOfClass:[NSArray class]]) {
        [fields[@"additionalIps"] setString:[extras componentsJoinedByString:@"\n"]];
    }
    NSString *storedKey = wsData[@"host_key_sha256"];
    if (storedKey.length > 0) {
        [fields[@"hostKey"] setStringValue:storedKey];
    }

    [win makeKeyAndOrderFront:nil];
}

// "Re-learn" button action. Runs `autofuse learn-host-key`
// against whichever endpoint is currently reachable and refreshes the field
// inline. Needed after a legitimate server reinstall, when the previously
// stored fingerprint no longer matches.
- (void)relearnHostKey:(NSButton *)sender {
    NSWindow *win = objc_getAssociatedObject(sender, &kWindowKey);
    NSDictionary *fields = objc_getAssociatedObject(win, &kFieldsKey);
    NSString *editMode = objc_getAssociatedObject(win, &kEditModeKey);
    NSString *name = [fields[@"name"] stringValue];
    if (name.length == 0) {
        NSAlert *a = [NSAlert new]; a.messageText = @"No Workstation Name";
        a.informativeText = @"Fill in Name and Save the workstation first, then use Re-learn."; [a runModal]; return;
    }
    // Require the workstation to already exist in config — learn-host-key
    // reads it from there. If still in __add__ mode, Save first.
    if ([editMode isEqualToString:@"__add__"]) {
        NSAlert *a = [NSAlert new]; a.messageText = @"Save First";
        a.informativeText = @"Save this workstation once, then use Re-learn to capture the host key."; [a runModal]; return;
    }

    NSString *origTitle = sender.title;
    sender.title = @"Learning…"; sender.enabled = NO;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *result = [self runScript:@[@"learn-host-key", name] timeout:15];
        dispatch_async(dispatch_get_main_queue(), ^{
            sender.title = origTitle; sender.enabled = YES;
            // Success line: "learned:<ws>|<endpoint>|SHA256:..."
            if ([result hasPrefix:@"learned:"]) {
                NSArray *parts = [[result substringFromIndex:8] componentsSeparatedByString:@"|"];
                if (parts.count >= 3) {
                    [fields[@"hostKey"] setStringValue:parts[2]];
                    NSAlert *a = [NSAlert new]; a.messageText = @"Host Key Captured";
                    a.informativeText = [NSString stringWithFormat:@"Fingerprint learned from %@:\n\n%@",
                                         parts[1], parts[2]];
                    [a runModal];
                    return;
                }
            }
            NSAlert *a = [NSAlert new]; a.messageText = @"Re-learn Failed";
            a.informativeText = result.length > 0 ? result : @"Unknown error (check connectivity + SSH key).";
            a.alertStyle = NSAlertStyleWarning; [a runModal];
        });
    });
}

- (void)removeWorkstation:(NSMenuItem *)sender {
    NSString *hostName = sender.representedObject;
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:@"Remove %@?", hostName];
    a.informativeText = @"Mounted disks will be unmounted.";
    [a addButtonWithTitle:@"Remove"]; [a addButtonWithTitle:@"Cancel"];
    a.alertStyle = NSAlertStyleWarning;
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    // Unmount in the background — a dead host's hung unmount (up to 30s) would
    // otherwise freeze the menu bar. Unmount BEFORE removing from config (the
    // unmount needs the config to resolve the mount point), then update on main.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self runScript:@[@"unmount", hostName]];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableDictionary *cfg = [self loadConfig];
            NSMutableArray *ws = cfg[@"workstations"];
            for (NSUInteger i = 0; i < ws.count; i++)
                if ([ws[i][@"name"] isEqualToString:hostName]) { [ws removeObjectAtIndex:i]; break; }
            [self saveConfig:cfg]; [self loadHosts]; [self refreshStatus]; [self buildMenu];
        });
    });
}

// ─── Discovery Actions ─────────────────────────────────────────────────────

- (void)discoverScanNetwork:(NSButton *)sender {
    NSWindow *parentWin = objc_getAssociatedObject(sender, &kWindowKey);
    NSDictionary *fields = objc_getAssociatedObject(parentWin, &kFieldsKey);

    // Show a progress alert while scanning
    NSAlert *progress = [NSAlert new];
    progress.messageText = @"Scanning Network...";
    progress.informativeText = @"Looking for SSH-capable hosts on the local network.\nThis may take up to 10 seconds.";
    progress.alertStyle = NSAlertStyleInformational;
    [progress addButtonWithTitle:@"Cancel"];

    // Run scan in background
    __block NSString *scanResult = nil;
    __block BOOL scanDone = NO;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        scanResult = [self runDiscover:@[@"scan-network"] timeout:12];
        scanDone = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (progress.window.isVisible) {
                [NSApp stopModalWithCode:NSModalResponseOK];
            }
        });
    });

    NSModalResponse resp = [progress runModal];
    if (resp != NSModalResponseOK && !scanDone) return;

    // Wait a moment for result if needed
    if (!scanDone) {
        for (int i = 0; i < 20 && !scanDone; i++)
            [NSThread sleepForTimeInterval:0.1];
    }
    if (!scanResult || scanResult.length == 0) {
        NSAlert *a = [NSAlert new]; a.messageText = @"No Hosts Found";
        a.informativeText = @"No hosts were discovered on the local network."; [a runModal]; return;
    }

    // Build a list of hosts for the user to pick
    NSMutableArray *hostEntries = [NSMutableArray new];
    for (NSString *line in [scanResult componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if (line.length == 0) continue;
        NSArray *parts = [line componentsSeparatedByString:@"|"];
        if (parts.count < 4) continue;
        [hostEntries addObject:parts];
    }
    if (hostEntries.count == 0) {
        NSAlert *a = [NSAlert new]; a.messageText = @"No Hosts Found";
        a.informativeText = @"No hosts were discovered on the local network."; [a runModal]; return;
    }

    // Show picker
    NSAlert *picker = [NSAlert new];
    picker.messageText = @"Select a Host";
    picker.informativeText = @"Choose a host to fill the LAN IP field:";
    [picker addButtonWithTitle:@"Select"];
    [picker addButtonWithTitle:@"Cancel"];

    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 350, 26) pullsDown:NO];
    for (NSArray *entry in hostEntries) {
        NSString *ip = entry[0];
        NSString *hostname = entry[1];
        NSString *mac = entry[2];
        NSString *sshOpen = entry.count > 3 ? entry[3] : @"no";
        NSString *smbOpen = entry.count > 4 ? entry[4] : @"no";
        NSString *sshTag = [sshOpen isEqualToString:@"yes"] ? @" [SSH]" : @"";
        NSString *smbTag = [smbOpen isEqualToString:@"yes"] ? @" [SMB]" : @"";
        NSString *label = hostname.length > 0
            ? [NSString stringWithFormat:@"%@ (%@)%@%@", ip, hostname, sshTag, smbTag]
            : [NSString stringWithFormat:@"%@%@%@", ip, sshTag, smbTag];
        if (mac.length > 0 && ![mac isEqualToString:@"(incomplete)"]) {
            label = [label stringByAppendingFormat:@"  MAC: %@", mac];
        }
        [popup addItemWithTitle:label];
    }
    picker.accessoryView = popup;

    if ([picker runModal] != NSAlertFirstButtonReturn) return;

    NSInteger idx = popup.indexOfSelectedItem;
    if (idx >= 0 && idx < (NSInteger)hostEntries.count) {
        NSArray *selected = hostEntries[idx];
        [fields[@"lan"] setStringValue:selected[0]];
        // Auto-fill MAC if available
        NSString *mac = selected[2];
        if (mac.length > 0 && ![mac isEqualToString:@"(incomplete)"] && [[fields[@"mac"] stringValue] length] == 0) {
            [fields[@"mac"] setStringValue:mac];
        }
        // Auto-fill hostname as name if empty
        NSString *hostname = selected[1];
        if (hostname.length > 0 && [[fields[@"name"] stringValue] length] == 0) {
            [fields[@"name"] setStringValue:hostname];
        }
    }
}

- (void)discoverImportSSH:(NSButton *)sender {
    NSWindow *parentWin = objc_getAssociatedObject(sender, &kWindowKey);
    NSDictionary *fields = objc_getAssociatedObject(parentWin, &kFieldsKey);

    NSString *sshResult = [self runDiscover:@[@"import-ssh-config"] timeout:5];
    if (!sshResult || sshResult.length == 0) {
        NSAlert *a = [NSAlert new]; a.messageText = @"No SSH Hosts";
        a.informativeText = @"No hosts found in ~/.ssh/config."; [a runModal]; return;
    }

    NSMutableArray *sshEntries = [NSMutableArray new];
    for (NSString *line in [sshResult componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if (line.length == 0) continue;
        NSArray *parts = [line componentsSeparatedByString:@"|"];
        if (parts.count < 5) continue;
        [sshEntries addObject:parts];
    }
    if (sshEntries.count == 0) {
        NSAlert *a = [NSAlert new]; a.messageText = @"No SSH Hosts";
        a.informativeText = @"No hosts found in ~/.ssh/config."; [a runModal]; return;
    }

    NSAlert *picker = [NSAlert new];
    picker.messageText = @"Import from SSH Config";
    picker.informativeText = @"Select an SSH host to import:";
    [picker addButtonWithTitle:@"Import"];
    [picker addButtonWithTitle:@"Cancel"];

    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 350, 26) pullsDown:NO];
    for (NSArray *entry in sshEntries) {
        NSString *alias = entry[0];
        NSString *hostname = entry[1];
        NSString *user = entry[2];
        NSString *label = [NSString stringWithFormat:@"%@ -> %@@%@", alias, user, hostname];
        [popup addItemWithTitle:label];
    }
    picker.accessoryView = popup;

    if ([picker runModal] != NSAlertFirstButtonReturn) return;

    NSInteger idx = popup.indexOfSelectedItem;
    if (idx >= 0 && idx < (NSInteger)sshEntries.count) {
        NSArray *selected = sshEntries[idx];
        NSString *alias = selected[0];
        NSString *hostname = selected[1];
        NSString *user = selected[2];
        // NSString *port = selected[3]; // not used in config currently
        NSString *keyfile = selected[4];

        if ([[fields[@"name"] stringValue] length] == 0) [fields[@"name"] setStringValue:alias];
        if (user.length > 0) [fields[@"user"] setStringValue:user];
        if (hostname.length > 0) [fields[@"lan"] setStringValue:hostname];
        if (keyfile.length > 0) [fields[@"key"] setStringValue:keyfile];
    }
}

// "Auto-detect" button inside the Add/Edit Workstation dialog. Runs
// `discover.sh probe-host` in the background and fills every field the
// probe returned (MAC address, detected OS, suggested protocol sshfs/smb,
// SMB share if available, disk list). While probing, the button shows
// "Probing..." and is disabled. Stays on the main thread ONLY for UI
// mutation; the NSTask and its output parsing happen on a background
// queue so the dialog stays responsive. Errors surface as an inline
// NSAlert, not a silent failure — the user always learns why probe failed
// (offline, no SSH, key rejected, …).
- (void)discoverAutoDetect:(NSButton *)sender {
    NSWindow *parentWin = objc_getAssociatedObject(sender, &kWindowKey);
    NSDictionary *fields = objc_getAssociatedObject(parentWin, &kFieldsKey);

    NSString *ip = [fields[@"lan"] stringValue];
    NSString *user = [fields[@"user"] stringValue];
    NSString *key = [fields[@"key"] stringValue];

    if (ip.length == 0 || user.length == 0) {
        NSAlert *a = [NSAlert new]; a.messageText = @"Missing Fields";
        a.informativeText = @"Fill in LAN IP and SSH User first before auto-detecting."; [a runModal]; return;
    }

    // Change button title to indicate progress
    NSString *origTitle = sender.title;
    sender.title = @"Probing...";
    sender.enabled = NO;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *args = [NSMutableArray arrayWithObjects:@"probe-host", ip, user, nil];
        if (key.length > 0) [args addObject:key];
        NSString *probeResult = [self runDiscover:args timeout:15];

        dispatch_async(dispatch_get_main_queue(), ^{
            sender.title = origTitle;
            sender.enabled = YES;

            if (!probeResult || probeResult.length == 0 || [probeResult containsString:@"error:"]) {
                NSAlert *a = [NSAlert new]; a.messageText = @"Probe Failed";
                a.informativeText = [NSString stringWithFormat:@"Could not probe %@@%@.\nCheck that SSH is accessible.", user, ip];
                a.alertStyle = NSAlertStyleWarning; [a runModal]; return;
            }

            // Parse probe results (tab-separated key-value pairs)
            NSString *detectedMAC = @"";
            NSString *detectedHostname = @"";
            NSString *detectedProtocol = @"sshfs";  // Default to SSHFS
            BOOL smbIsAvailable = NO;
            NSMutableArray *detectedDisks = [NSMutableArray new];

            for (NSString *line in [probeResult componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                if (line.length == 0) continue;
                NSArray *kv = [line componentsSeparatedByString:@"\t"];
                if (kv.count < 2) continue;
                NSString *k = kv[0];
                NSString *v = kv[1];

                if ([k isEqualToString:@"mac"] && v.length > 0) {
                    detectedMAC = v;
                } else if ([k isEqualToString:@"hostname"] && v.length > 0) {
                    detectedHostname = v;
                } else if ([k isEqualToString:@"protocol"] && v.length > 0) {
                    detectedProtocol = v;
                } else if ([k isEqualToString:@"smb_available"] && [v isEqualToString:@"yes"]) {
                    smbIsAvailable = YES;
                } else if ([k isEqualToString:@"disk"] && v.length > 0) {
                    [detectedDisks addObject:v];
                }
            }

            // Fill MAC
            if (detectedMAC.length > 0) {
                [fields[@"mac"] setStringValue:detectedMAC];
            }

            // Set protocol dropdown based on detected protocol
            NSPopUpButton *protocolBtn = fields[@"protocol"];
            if (protocolBtn) {
                [protocolBtn selectItemWithTitle:detectedProtocol];
                // Update SMB share field visibility based on detected protocol
                NSTextField *smbShareField = fields[@"smbShare"];
                if (smbShareField) {
                    smbShareField.hidden = ![detectedProtocol isEqualToString:@"smb"];
                }
            }

            // Fill name if empty
            if ([[fields[@"name"] stringValue] length] == 0 && detectedHostname.length > 0) {
                [fields[@"name"] setStringValue:detectedHostname];
            }

            // Fill disks
            if (detectedDisks.count > 0) {
                NSMutableString *diskLines = [NSMutableString new];
                for (NSString *diskEntry in detectedDisks) {
                    // Format from probe: letter|label|used|total  OR  path||used|total
                    NSArray *dp = [diskEntry componentsSeparatedByString:@"|"];
                    if (dp.count >= 1) {
                        NSString *letter = dp[0];
                        NSString *label = dp.count > 1 ? dp[1] : @"";
                        // For Windows drives: letter is single char like C, remote_path = /C:/
                        // For Linux/macOS: letter is mount path like /home, remote_path = /home
                        NSString *remotePath;
                        if (letter.length == 1 && [[NSCharacterSet uppercaseLetterCharacterSet]
                                characterIsMember:[letter characterAtIndex:0]]) {
                            remotePath = [NSString stringWithFormat:@"/%@:/", letter];
                        } else {
                            remotePath = letter;
                            // Use last path component as short letter
                            letter = [letter lastPathComponent];
                            if (letter.length == 0) letter = @"root";
                        }
                        if (label.length == 0) label = letter;
                        // Append size info to LABEL (not remote_path) to avoid corrupting the path
                        if (dp.count >= 4) {
                            NSString *used = dp[2];
                            NSString *total = dp[3];
                            if (used.length > 0 && total.length > 0) {
                                label = [NSString stringWithFormat:@"%@ (%@/%@ GB)", label, used, total];
                            }
                        }
                        [diskLines appendFormat:@"%@, %@, %@\n", letter, label, remotePath];
                    }
                }
                [fields[@"disks"] setString:diskLines];
            }

            // Show summary
            NSMutableString *summary = [NSMutableString stringWithString:@"Auto-detect complete:\n"];
            if (detectedHostname.length > 0) [summary appendFormat:@"  Hostname: %@\n", detectedHostname];
            if (detectedMAC.length > 0) [summary appendFormat:@"  MAC: %@\n", detectedMAC];
            [summary appendFormat:@"  Protocol: %@", detectedProtocol];
            if (smbIsAvailable) [summary appendString:@" (SMB also available)"];
            [summary appendString:@"\n"];
            [summary appendFormat:@"  Disks found: %ld", (long)detectedDisks.count];

            NSAlert *a = [NSAlert new];
            a.messageText = @"Probe Results";
            a.informativeText = summary;
            a.alertStyle = NSAlertStyleInformational;
            [a runModal];
        });
    });
}

// ─── Setup Wizard ──────────────────────────────────────────────────────────

// 4-step onboarding wizard for users with zero AutoFuse/SSH experience:
//   1. FUSE backend check — verifies macFUSE or FUSE-T is installed
//   2. SSH key creation — runs `ssh-keygen` if no key exists
//   3. Host discovery — auto-scans the LAN and suggests targets
//   4. First mount — wires the user's first workstation into config.json
// State is held via associated objects on the NSWindow (`kWizardStepKey`,
// `kWizardDataKey`) rather than instance properties, so opening a second
// wizard doesn't clobber an in-progress one. Layout uses an NSScrollView
// middle region with pinned top (title) and bottom (Back/Next buttons) so
// long step content never collides with the navigation row — earlier
// hard-coded coordinates caused overlap on small displays.
- (void)showSetupWizard:(id)sender {
    if (self.wizardWindow && self.wizardWindow.isVisible) {
        [self.wizardWindow makeKeyAndOrderFront:nil];
        return;
    }
    [NSApp activateIgnoringOtherApps:YES];

    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 620, 580)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    win.title = @"AutoFuse Setup Guide";
    [win center];
    win.level = NSFloatingWindowLevel;
    win.delegate = self;
    win.releasedWhenClosed = NO;  // ARC: red-X close must not dealloc the window (crash on reopen)

    // Store wizard state as associated objects
    NSMutableDictionary *wizardData = [NSMutableDictionary dictionaryWithDictionary:@{
        @"fuseBackend": @"",
        @"sshKeyPath": @"~/.ssh/id_ed25519",
        @"wsName": @"",
        @"wsIP": @"",
        @"wsUser": @"",
        @"wsMAC": @"",
        @"wsDisks": @""
    }];
    objc_setAssociatedObject(win, &kWizardDataKey, wizardData, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(win, &kWizardStepKey, @(1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    self.wizardWindow = win;
    [self wizardShowStep:1 inWindow:win];
    [win makeKeyAndOrderFront:nil];
}

- (void)wizardShowStep:(NSInteger)step inWindow:(NSWindow *)win {
    objc_setAssociatedObject(win, &kWizardStepKey, @(step), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Clear content view
    NSView *cv = win.contentView;
    for (NSView *sub in [cv.subviews copy]) [sub removeFromSuperview];

    switch (step) {
        case 1: [self wizardBuildStep1:win]; break;
        case 2: [self wizardBuildStep2:win]; break;
        case 3: [self wizardBuildStep3:win]; break;
        case 4: [self wizardBuildStep4:win]; break;
        default: break;
    }
}

// ─── Step 1: FUSE Backend Check ────────────────────────────────────────────

- (void)wizardBuildStep1:(NSWindow *)win {
    NSView *cv = win.contentView;
    CGFloat W = cv.frame.size.width;
    CGFloat H = cv.frame.size.height;

    // Fixed top area
    CGFloat topY = H - 30;
    NSTextField *stepLabel = [self makeLabel:@"Step 1 of 4" frame:NSMakeRect(20, topY, W-40, 16)];
    stepLabel.font = [NSFont systemFontOfSize:11];
    stepLabel.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:stepLabel]; topY -= 26;

    NSTextField *title = [self makeLabel:@"Install Software for Remote Disks" frame:NSMakeRect(20, topY, W-40, 24)];
    title.font = [NSFont boldSystemFontOfSize:18];
    [cv addSubview:title]; topY -= 24;

    NSTextField *subtitle = [self makeLabel:@"AutoFuse needs special software to let your Mac see files on remote computers." frame:NSMakeRect(20, topY, W-40, 18)];
    subtitle.font = [NSFont systemFontOfSize:12];
    subtitle.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:subtitle];

    // Fixed bottom navigation buttons
    CGFloat btnY = 20;
    NSButton *checkAgain = [[NSButton alloc] initWithFrame:NSMakeRect(20, btnY, 120, 32)];
    checkAgain.title = @"Check Again"; checkAgain.bezelStyle = NSBezelStyleRounded;
    checkAgain.target = self; checkAgain.action = @selector(wizardCheckAgain:);
    objc_setAssociatedObject(checkAgain, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    [cv addSubview:checkAgain];

    // Check current status
    NSString *depsResult = [self runScript:@[@"check-deps"]];
    BOOL fuseOK = [depsResult containsString:@"ok:sshfs:"];
    NSString *backendName = @"";
    if ([depsResult containsString:@"macfuse"]) backendName = @"macFUSE";
    else if ([depsResult containsString:@"fuset"]) backendName = @"FUSE-T";

    NSButton *nextBtn = [[NSButton alloc] initWithFrame:NSMakeRect(W-120, btnY, 80, 32)];
    nextBtn.title = @"Next"; nextBtn.bezelStyle = NSBezelStyleRounded;
    nextBtn.keyEquivalent = @"\r";
    nextBtn.target = self; nextBtn.action = @selector(wizardNext:);
    nextBtn.enabled = fuseOK;
    objc_setAssociatedObject(nextBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    [cv addSubview:nextBtn];

    // Scrollable middle area
    CGFloat scrollTop = topY - 24;
    CGFloat scrollBottom = btnY + 44;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:
        NSMakeRect(0, scrollBottom, W, scrollTop - scrollBottom)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;

    CGFloat contentHeight = 400;
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, contentHeight)];
    CGFloat y = contentHeight - 10;

    if (fuseOK) {
        // Store detected backend
        NSMutableDictionary *data = objc_getAssociatedObject(win, &kWizardDataKey);
        data[@"fuseBackend"] = backendName;

        NSImage *checkImg = [self sfSymbol:@"checkmark.circle.fill" size:24 color:[NSColor systemGreenColor]];
        NSImageView *checkView = [[NSImageView alloc] initWithFrame:NSMakeRect(20, y - 28, 28, 28)];
        checkView.image = checkImg;
        [content addSubview:checkView];

        NSTextField *okLabel = [self makeLabel:[NSString stringWithFormat:@"%@ detected and working", backendName]
                                         frame:NSMakeRect(56, y - 24, 500, 20)];
        okLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
        okLabel.textColor = [NSColor systemGreenColor];
        [content addSubview:okLabel]; y -= 40;

        NSTextField *info = [self makeLabel:@"Everything is set up. You can continue to the next step."
                                      frame:NSMakeRect(20, y - 18, W-40, 18)];
        info.font = [NSFont systemFontOfSize:12];
        [content addSubview:info];
    } else {
        NSImage *warnImg = [self sfSymbol:@"exclamationmark.triangle.fill" size:24 color:[NSColor systemOrangeColor]];
        NSImageView *warnView = [[NSImageView alloc] initWithFrame:NSMakeRect(20, y - 28, 28, 28)];
        warnView.image = warnImg;
        [content addSubview:warnView];

        NSTextField *notFound = [self makeLabel:@"No remote disk software found"
                                          frame:NSMakeRect(56, y - 24, 500, 20)];
        notFound.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
        notFound.textColor = [NSColor systemOrangeColor];
        [content addSubview:notFound]; y -= 40;

        // Option A: FUSE-T
        NSBox *boxA = [[NSBox alloc] initWithFrame:NSMakeRect(20, y - 130, W-40, 130)];
        boxA.title = @"Option A (Recommended): FUSE-T";
        boxA.titleFont = [NSFont boldSystemFontOfSize:12];
        [content addSubview:boxA];

        NSTextField *descA = [self makeLabel:@"No kernel extension needed. Works on all Macs including Apple Silicon."
                                       frame:NSMakeRect(12, 76, 530, 18)];
        descA.font = [NSFont systemFontOfSize:11];
        descA.textColor = [NSColor secondaryLabelColor];
        [boxA.contentView addSubview:descA];

        NSTextField *cmdA = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 40, 530, 30)];
        cmdA.stringValue = @"brew tap macos-fuse-t/homebrew-cask && brew install fuse-t && brew install fuse-t-sshfs";
        cmdA.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
        cmdA.editable = NO; cmdA.selectable = YES; cmdA.bezeled = YES;
        cmdA.bezelStyle = NSTextFieldRoundedBezel;
        cmdA.backgroundColor = [NSColor controlBackgroundColor];
        [boxA.contentView addSubview:cmdA];

        NSButton *copyA = [[NSButton alloc] initWithFrame:NSMakeRect(12, 6, 120, 28)];
        copyA.title = @"Copy to Clipboard"; copyA.bezelStyle = NSBezelStyleRounded;
        copyA.font = [NSFont systemFontOfSize:11];
        copyA.tag = 7001;
        copyA.target = self; copyA.action = @selector(wizardCopyFuseT:);
        [boxA.contentView addSubview:copyA];

        NSButton *termA = [[NSButton alloc] initWithFrame:NSMakeRect(140, 6, 100, 28)];
        termA.title = @"Open Terminal"; termA.bezelStyle = NSBezelStyleRounded;
        termA.font = [NSFont systemFontOfSize:11];
        termA.target = self; termA.action = @selector(wizardOpenTerminal:);
        [boxA.contentView addSubview:termA];

        y -= 148;

        // Option B: macFUSE
        NSBox *boxB = [[NSBox alloc] initWithFrame:NSMakeRect(20, y - 90, W-40, 90)];
        boxB.title = @"Option B: macFUSE";
        boxB.titleFont = [NSFont boldSystemFontOfSize:12];
        [content addSubview:boxB];

        NSTextField *descB = [self makeLabel:@"Requires a kernel extension. Apple Silicon Macs may need Recovery Mode to enable it."
                                       frame:NSMakeRect(12, 36, 530, 18)];
        descB.font = [NSFont systemFontOfSize:11];
        descB.textColor = [NSColor secondaryLabelColor];
        [boxB.contentView addSubview:descB];

        NSTextField *noteB = [self makeLabel:@"After installing macFUSE, also run:  brew install sshfs"
                                       frame:NSMakeRect(12, 20, 530, 18)];
        noteB.font = [NSFont systemFontOfSize:11];
        [boxB.contentView addSubview:noteB];

        NSButton *openSite = [[NSButton alloc] initWithFrame:NSMakeRect(12, 0, 160, 22)];
        openSite.title = @"Open macFUSE Website"; openSite.bezelStyle = NSBezelStyleRounded;
        openSite.font = [NSFont systemFontOfSize:11];
        openSite.target = self; openSite.action = @selector(wizardOpenMacFUSESite:);
        [boxB.contentView addSubview:openSite];
    }

    scroll.documentView = content;
    [content scrollPoint:NSMakePoint(0, contentHeight)];
    [cv addSubview:scroll];
}

- (void)wizardCopyFuseT:(NSButton *)sender {
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:@"brew tap macos-fuse-t/homebrew-cask && brew install fuse-t && brew install fuse-t-sshfs"
                                        forType:NSPasteboardTypeString];
    sender.title = @"Copied!";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        sender.title = @"Copy to Clipboard";
    });
}

- (void)wizardOpenTerminal:(NSButton *)sender {
    NSTask *t = [NSTask new];
    t.launchPath = @"/usr/bin/open";
    t.arguments = @[@"-a", @"Terminal"];
    @try { [t launch]; } @catch (NSException *e) {}
}

- (void)wizardOpenMacFUSESite:(NSButton *)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://osxfuse.github.io"]];
}

- (void)wizardCheckAgain:(NSButton *)sender {
    NSWindow *win = objc_getAssociatedObject(sender, &kWindowKey);
    if (!win) win = self.wizardWindow;
    [self wizardShowStep:1 inWindow:win];
}

// ─── Step 2: SSH Key ───────────────────────────────────────────────────────

- (void)wizardBuildStep2:(NSWindow *)win {
    NSView *cv = win.contentView;
    NSMutableDictionary *data = objc_getAssociatedObject(win, &kWizardDataKey);
    CGFloat W = cv.frame.size.width;
    CGFloat H = cv.frame.size.height;

    // Fixed top area
    CGFloat topY = H - 30;
    NSTextField *stepLabel = [self makeLabel:@"Step 2 of 4" frame:NSMakeRect(20, topY, W-40, 16)];
    stepLabel.font = [NSFont systemFontOfSize:11];
    stepLabel.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:stepLabel]; topY -= 26;

    NSTextField *title = [self makeLabel:@"Secure Login Key" frame:NSMakeRect(20, topY, W-40, 24)];
    title.font = [NSFont boldSystemFontOfSize:18];
    [cv addSubview:title]; topY -= 24;

    NSTextField *subtitle = [self makeLabel:@"An SSH key lets you log into remote computers without a password. It is more secure and convenient."
                                      frame:NSMakeRect(20, topY, W-40, 18)];
    subtitle.font = [NSFont systemFontOfSize:12];
    subtitle.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:subtitle];

    // Fixed bottom navigation
    CGFloat btnY = 20;
    NSButton *backBtn = [[NSButton alloc] initWithFrame:NSMakeRect(20, btnY, 80, 32)];
    backBtn.title = @"Back"; backBtn.bezelStyle = NSBezelStyleRounded;
    backBtn.target = self; backBtn.action = @selector(wizardBack:);
    objc_setAssociatedObject(backBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    [cv addSubview:backBtn];

    NSButton *nextBtn = [[NSButton alloc] initWithFrame:NSMakeRect(W-120, btnY, 80, 32)];
    nextBtn.title = @"Next"; nextBtn.bezelStyle = NSBezelStyleRounded;
    nextBtn.keyEquivalent = @"\r";
    nextBtn.target = self; nextBtn.action = @selector(wizardNext:);
    objc_setAssociatedObject(nextBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    [cv addSubview:nextBtn];

    // Scrollable middle area
    CGFloat scrollTop = topY - 24;
    CGFloat scrollBottom = btnY + 44;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:
        NSMakeRect(0, scrollBottom, W, scrollTop - scrollBottom)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;

    CGFloat contentHeight = 500;
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, contentHeight)];
    CGFloat y = contentHeight - 10;

    NSString *keyPath = [NSHomeDirectory() stringByAppendingPathComponent:@".ssh/id_ed25519"];
    NSString *pubKeyPath = [keyPath stringByAppendingString:@".pub"];
    BOOL keyExists = [[NSFileManager defaultManager] fileExistsAtPath:keyPath];

    if (keyExists) {
        NSImage *checkImg = [self sfSymbol:@"checkmark.circle.fill" size:24 color:[NSColor systemGreenColor]];
        NSImageView *checkView = [[NSImageView alloc] initWithFrame:NSMakeRect(20, y - 28, 28, 28)];
        checkView.image = checkImg;
        [content addSubview:checkView];

        // Get fingerprint
        NSTask *fpTask = [NSTask new];
        fpTask.launchPath = @"/usr/bin/ssh-keygen";
        fpTask.arguments = @[@"-lf", keyPath];
        NSPipe *fpPipe = [NSPipe pipe];
        fpTask.standardOutput = fpPipe; fpTask.standardError = [NSPipe pipe];
        NSString *fingerprint = @"";
        @try {
            [fpTask launch]; [fpTask waitUntilExit];
            fingerprint = [[NSString alloc] initWithData:[fpPipe.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding] ?: @"";
            fingerprint = [fingerprint stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        } @catch (NSException *e) {}

        NSTextField *okLabel = [self makeLabel:[NSString stringWithFormat:@"SSH key found: ~/.ssh/id_ed25519"]
                                         frame:NSMakeRect(56, y - 24, 500, 20)];
        okLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
        okLabel.textColor = [NSColor systemGreenColor];
        [content addSubview:okLabel]; y -= 40;

        if (fingerprint.length > 0) {
            NSTextField *fpLabel = [self makeLabel:fingerprint frame:NSMakeRect(56, y - 16, 520, 16)];
            fpLabel.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
            fpLabel.textColor = [NSColor secondaryLabelColor];
            [content addSubview:fpLabel]; y -= 28;
        }

        data[@"sshKeyPath"] = @"~/.ssh/id_ed25519";
    } else {
        NSImage *infoImg = [self sfSymbol:@"info.circle.fill" size:24 color:[NSColor systemBlueColor]];
        NSImageView *infoView = [[NSImageView alloc] initWithFrame:NSMakeRect(20, y - 28, 28, 28)];
        infoView.image = infoImg;
        [content addSubview:infoView];

        NSTextField *noKey = [self makeLabel:@"No SSH key found"
                                       frame:NSMakeRect(56, y - 24, 500, 20)];
        noKey.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
        [content addSubview:noKey]; y -= 36;

        NSTextField *genDesc = [self makeLabel:@"Click the button below to create a new secure login key. This only takes a moment."
                                         frame:NSMakeRect(20, y - 18, W-40, 18)];
        genDesc.font = [NSFont systemFontOfSize:12];
        [content addSubview:genDesc]; y -= 36;

        NSButton *genBtn = [[NSButton alloc] initWithFrame:NSMakeRect(20, y - 32, 160, 32)];
        genBtn.title = @"Generate SSH Key"; genBtn.bezelStyle = NSBezelStyleRounded;
        genBtn.target = self; genBtn.action = @selector(wizardGenerateKey:);
        objc_setAssociatedObject(genBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
        [content addSubview:genBtn]; y -= 40;
    }

    // Public key display
    y -= 10;
    NSTextField *pubLabel = [self makeLabel:@"Your Public Key (safe to share):" frame:NSMakeRect(20, y - 18, 300, 18)];
    pubLabel.font = [NSFont boldSystemFontOfSize:12];
    [content addSubview:pubLabel]; y -= 24;

    NSString *pubKeyContent = @"(No public key found. Generate or locate your key first.)";
    if ([[NSFileManager defaultManager] fileExistsAtPath:pubKeyPath]) {
        pubKeyContent = [NSString stringWithContentsOfFile:pubKeyPath encoding:NSUTF8StringEncoding error:nil] ?: @"(Could not read key)";
        pubKeyContent = [pubKeyContent stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    NSScrollView *pubScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, y - 66, W-40, 66)];
    pubScroll.hasVerticalScroller = YES; pubScroll.borderType = NSBezelBorder;
    NSTextView *pubText = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, W-40, 66)];
    pubText.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    pubText.string = pubKeyContent;
    pubText.editable = NO;
    pubText.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    pubScroll.documentView = pubText;
    [content addSubview:pubScroll]; y -= 76;

    NSButton *copyPub = [[NSButton alloc] initWithFrame:NSMakeRect(20, y - 28, 130, 28)];
    copyPub.title = @"Copy Public Key"; copyPub.bezelStyle = NSBezelStyleRounded;
    copyPub.font = [NSFont systemFontOfSize:11];
    copyPub.target = self; copyPub.action = @selector(wizardCopyPublicKey:);
    objc_setAssociatedObject(copyPub, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    [content addSubview:copyPub]; y -= 36;

    NSTextField *explain = [self makeLabel:@"This public key needs to be added to each remote computer you want to connect to.\nThe private key stays on this Mac and is never shared."
                                     frame:NSMakeRect(20, y - 32, W-40, 32)];
    explain.font = [NSFont systemFontOfSize:11];
    explain.textColor = [NSColor secondaryLabelColor];
    [content addSubview:explain];

    scroll.documentView = content;
    [content scrollPoint:NSMakePoint(0, contentHeight)];
    [cv addSubview:scroll];
}

- (void)wizardGenerateKey:(NSButton *)sender {
    NSWindow *win = objc_getAssociatedObject(sender, &kWindowKey);
    sender.enabled = NO;
    sender.title = @"Generating...";

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *sshDir = [NSHomeDirectory() stringByAppendingPathComponent:@".ssh"];
        [[NSFileManager defaultManager] createDirectoryAtPath:sshDir withIntermediateDirectories:YES attributes:nil error:nil];

        NSString *keyPath = [sshDir stringByAppendingPathComponent:@"id_ed25519"];
        NSTask *t = [NSTask new];
        t.launchPath = @"/usr/bin/ssh-keygen";
        t.arguments = @[@"-t", @"ed25519", @"-N", @"", @"-f", keyPath];
        t.standardOutput = [NSPipe pipe];
        t.standardError = [NSPipe pipe];
        BOOL ok = NO;
        @try {
            [t launch]; [t waitUntilExit];
            ok = (t.terminationStatus == 0);
        } @catch (NSException *e) {}

        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                NSAlert *a = [NSAlert new];
                a.messageText = @"SSH Key Generated";
                a.informativeText = @"A new secure login key has been created at ~/.ssh/id_ed25519";
                a.alertStyle = NSAlertStyleInformational;
                [a runModal];
            } else {
                NSAlert *a = [NSAlert new];
                a.messageText = @"Key Generation Failed";
                a.informativeText = @"Could not create an SSH key. You may need to create one manually in Terminal.";
                a.alertStyle = NSAlertStyleWarning;
                [a runModal];
            }
            // Rebuild step 2 to show the key
            [self wizardShowStep:2 inWindow:win];
        });
    });
}

- (void)wizardCopyPublicKey:(NSButton *)sender {
    NSString *pubKeyPath = [NSHomeDirectory() stringByAppendingPathComponent:@".ssh/id_ed25519.pub"];
    NSString *content = [NSString stringWithContentsOfFile:pubKeyPath encoding:NSUTF8StringEncoding error:nil];
    if (content.length > 0) {
        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:[content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                                            forType:NSPasteboardTypeString];
        sender.title = @"Copied!";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            sender.title = @"Copy Public Key";
        });
    } else {
        NSAlert *a = [NSAlert new];
        a.messageText = @"No Public Key";
        a.informativeText = @"Could not read the public key file. Generate a key first.";
        [a runModal];
    }
}

// ─── Step 3: Add First Workstation ─────────────────────────────────────────

- (void)wizardBuildStep3:(NSWindow *)win {
    NSView *cv = win.contentView;
    NSMutableDictionary *data = objc_getAssociatedObject(win, &kWizardDataKey);
    CGFloat W = cv.frame.size.width;
    CGFloat H = cv.frame.size.height;

    // Fixed top area
    CGFloat topY = H - 30;
    NSTextField *stepLabel = [self makeLabel:@"Step 3 of 4" frame:NSMakeRect(20, topY, W-40, 16)];
    stepLabel.font = [NSFont systemFontOfSize:11];
    stepLabel.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:stepLabel]; topY -= 26;

    NSTextField *title = [self makeLabel:@"Connect to a Remote Computer" frame:NSMakeRect(20, topY, W-40, 24)];
    title.font = [NSFont boldSystemFontOfSize:18];
    [cv addSubview:title]; topY -= 24;

    NSTextField *subtitle = [self makeLabel:@"Enter the details of the remote computer you want to access, or scan your network to find it."
                                      frame:NSMakeRect(20, topY, W-40, 18)];
    subtitle.font = [NSFont systemFontOfSize:12];
    subtitle.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:subtitle];

    // Fixed bottom navigation
    CGFloat btnY = 20;
    NSButton *backBtn = [[NSButton alloc] initWithFrame:NSMakeRect(20, btnY, 80, 32)];
    backBtn.title = @"Back"; backBtn.bezelStyle = NSBezelStyleRounded;
    backBtn.target = self; backBtn.action = @selector(wizardBack:);
    objc_setAssociatedObject(backBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    [cv addSubview:backBtn];

    NSButton *skipBtn = [[NSButton alloc] initWithFrame:NSMakeRect(W-230, btnY, 100, 32)];
    skipBtn.title = @"Skip"; skipBtn.bezelStyle = NSBezelStyleRounded;
    skipBtn.target = self; skipBtn.action = @selector(wizardSkipToFinish:);
    objc_setAssociatedObject(skipBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    [cv addSubview:skipBtn];

    NSButton *nextBtn = [[NSButton alloc] initWithFrame:NSMakeRect(W-120, btnY, 80, 32)];
    nextBtn.title = @"Next"; nextBtn.bezelStyle = NSBezelStyleRounded;
    nextBtn.keyEquivalent = @"\r";
    nextBtn.target = self; nextBtn.action = @selector(wizardSaveAndNext:);
    objc_setAssociatedObject(nextBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    [cv addSubview:nextBtn];

    // Scrollable middle area
    CGFloat scrollTop = topY - 24;
    CGFloat scrollBottom = btnY + 44;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:
        NSMakeRect(0, scrollBottom, W, scrollTop - scrollBottom)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;

    CGFloat contentHeight = 600;
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, contentHeight)];
    CGFloat y = contentHeight - 10;

    // Auto-discover section
    NSBox *discoverBox = [[NSBox alloc] initWithFrame:NSMakeRect(20, y - 52, W-40, 52)];
    discoverBox.title = @"Auto-Discover";
    discoverBox.titleFont = [NSFont boldSystemFontOfSize:11];
    [content addSubview:discoverBox];

    NSButton *scanBtn = [[NSButton alloc] initWithFrame:NSMakeRect(10, 2, 140, 24)];
    scanBtn.title = @"Scan My Network"; scanBtn.bezelStyle = NSBezelStyleRounded;
    scanBtn.font = [NSFont systemFontOfSize:11];
    scanBtn.target = self; scanBtn.action = @selector(wizardScanNetwork:);
    objc_setAssociatedObject(scanBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    [discoverBox.contentView addSubview:scanBtn];

    NSButton *importBtn = [[NSButton alloc] initWithFrame:NSMakeRect(158, 2, 180, 24)];
    importBtn.title = @"Import from SSH Config"; importBtn.bezelStyle = NSBezelStyleRounded;
    importBtn.font = [NSFont systemFontOfSize:11];
    importBtn.target = self; importBtn.action = @selector(wizardImportSSH:);
    objc_setAssociatedObject(importBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    [discoverBox.contentView addSubview:importBtn];

    y -= 62;

    // Manual entry fields
    CGFloat lw = 100, fw = 200;

    [content addSubview:[self makeLabel:@"IP Address:" frame:NSMakeRect(20, y - 20, lw, 20)]];
    NSTextField *ipField = [self makeField:@"e.g. 192.168.1.100" frame:NSMakeRect(124, y - 22, fw, 22)];
    ipField.stringValue = data[@"wsIP"] ?: @"";
    ipField.tag = 8001;
    [content addSubview:ipField]; y -= 30;

    [content addSubview:[self makeLabel:@"Username:" frame:NSMakeRect(20, y - 20, lw, 20)]];
    NSTextField *userField = [self makeField:@"e.g. admin" frame:NSMakeRect(124, y - 22, fw, 22)];
    userField.stringValue = data[@"wsUser"] ?: @"";
    userField.tag = 8002;
    [content addSubview:userField]; y -= 30;

    [content addSubview:[self makeLabel:@"SSH Key:" frame:NSMakeRect(20, y - 20, lw, 20)]];
    NSTextField *keyField = [self makeField:@"~/.ssh/id_ed25519" frame:NSMakeRect(124, y - 22, fw, 22)];
    keyField.stringValue = data[@"sshKeyPath"] ?: @"~/.ssh/id_ed25519";
    keyField.tag = 8003;
    [content addSubview:keyField]; y -= 36;

    // Action buttons row
    NSButton *testBtn = [[NSButton alloc] initWithFrame:NSMakeRect(20, y - 28, 130, 28)];
    testBtn.title = @"Test Connection"; testBtn.bezelStyle = NSBezelStyleRounded;
    testBtn.font = [NSFont systemFontOfSize:11];
    testBtn.target = self; testBtn.action = @selector(wizardTestConnection:);
    objc_setAssociatedObject(testBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    [content addSubview:testBtn];

    NSButton *copyKeyBtn = [[NSButton alloc] initWithFrame:NSMakeRect(158, y - 28, 170, 28)];
    copyKeyBtn.title = @"Copy Key to Server..."; copyKeyBtn.bezelStyle = NSBezelStyleRounded;
    copyKeyBtn.font = [NSFont systemFontOfSize:11];
    copyKeyBtn.target = self; copyKeyBtn.action = @selector(wizardCopyKeyToServer:);
    objc_setAssociatedObject(copyKeyBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    [content addSubview:copyKeyBtn];

    NSButton *detectBtn = [[NSButton alloc] initWithFrame:NSMakeRect(336, y - 28, 170, 28)];
    detectBtn.title = @"Detect Computer Details"; detectBtn.bezelStyle = NSBezelStyleRounded;
    detectBtn.font = [NSFont systemFontOfSize:11];
    detectBtn.target = self; detectBtn.action = @selector(wizardDetectDetails:);
    objc_setAssociatedObject(detectBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    [content addSubview:detectBtn]; y -= 36;

    // Detected info area
    NSTextField *nameLabel = [self makeLabel:@"Computer Name:" frame:NSMakeRect(20, y - 20, lw + 20, 20)];
    nameLabel.font = [NSFont systemFontOfSize:11];
    [content addSubview:nameLabel];
    NSTextField *nameField = [self makeField:@"(auto-detected)" frame:NSMakeRect(144, y - 22, fw, 22)];
    nameField.stringValue = data[@"wsName"] ?: @"";
    nameField.tag = 8004;
    [content addSubview:nameField]; y -= 28;

    NSTextField *macLabel = [self makeLabel:@"MAC Address:" frame:NSMakeRect(20, y - 20, lw + 20, 20)];
    macLabel.font = [NSFont systemFontOfSize:11];
    [content addSubview:macLabel];
    NSTextField *macField = [self makeField:@"(for Wake-on-LAN)" frame:NSMakeRect(144, y - 22, fw, 22)];
    macField.stringValue = data[@"wsMAC"] ?: @"";
    macField.tag = 8005;
    [content addSubview:macField]; y -= 28;

    // Disks area
    NSTextField *disksLabel = [self makeLabel:@"Remote Disks:" frame:NSMakeRect(20, y - 18, 200, 18)];
    disksLabel.font = [NSFont boldSystemFontOfSize:11];
    [content addSubview:disksLabel]; y -= 22;

    NSScrollView *diskScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, y - 74, W-40, 74)];
    diskScroll.hasVerticalScroller = YES; diskScroll.borderType = NSBezelBorder;
    NSTextView *disksText = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, W-40, 74)];
    disksText.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    disksText.string = [data[@"wsDisks"] length] > 0 ? data[@"wsDisks"] : @"C, System, /C:/\nD, Data, /D:/";
    disksText.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    diskScroll.documentView = disksText;
    objc_setAssociatedObject(win, &kFieldsKey, @{
        @"ip": ipField, @"user": userField, @"key": keyField,
        @"name": nameField, @"mac": macField, @"disks": disksText
    }, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [content addSubview:diskScroll]; y -= 80;

    NSTextField *diskHelp = [self makeLabel:@"Format: letter, label, remote_path  (one disk per line)"
                                      frame:NSMakeRect(20, y - 14, 400, 14)];
    diskHelp.font = [NSFont systemFontOfSize:10];
    diskHelp.textColor = [NSColor tertiaryLabelColor];
    [content addSubview:diskHelp];

    scroll.documentView = content;
    [content scrollPoint:NSMakePoint(0, contentHeight)];
    [cv addSubview:scroll];
}

- (void)wizardScanNetwork:(NSButton *)sender {
    NSWindow *win = objc_getAssociatedObject(sender, &kWindowKey);
    NSDictionary *fields = objc_getAssociatedObject(win, &kFieldsKey);

    sender.enabled = NO; sender.title = @"Scanning...";

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *result = [self runDiscover:@[@"scan-network"] timeout:12];
        dispatch_async(dispatch_get_main_queue(), ^{
            sender.enabled = YES; sender.title = @"Scan My Network";

            if (!result || result.length == 0) {
                NSAlert *a = [NSAlert new]; a.messageText = @"No Hosts Found";
                a.informativeText = @"No computers were found on your network. Make sure the remote computer is on and connected.";
                [a runModal]; return;
            }

            NSMutableArray *hostEntries = [NSMutableArray new];
            for (NSString *line in [result componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                if (line.length == 0) continue;
                NSArray *parts = [line componentsSeparatedByString:@"|"];
                if (parts.count >= 4) [hostEntries addObject:parts];
            }
            if (hostEntries.count == 0) {
                NSAlert *a = [NSAlert new]; a.messageText = @"No Hosts Found";
                a.informativeText = @"No SSH-capable computers found on the network."; [a runModal]; return;
            }

            NSAlert *picker = [NSAlert new];
            picker.messageText = @"Select a Computer";
            picker.informativeText = @"These computers were found on your network:";
            [picker addButtonWithTitle:@"Select"]; [picker addButtonWithTitle:@"Cancel"];

            NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 400, 26) pullsDown:NO];
            for (NSArray *entry in hostEntries) {
                NSString *sshTag = [entry[3] isEqualToString:@"yes"] ? @" [SSH available]" : @"";
                NSString *label = entry[1] && [entry[1] length] > 0
                    ? [NSString stringWithFormat:@"%@ (%@)%@", entry[0], entry[1], sshTag]
                    : [NSString stringWithFormat:@"%@%@", entry[0], sshTag];
                [popup addItemWithTitle:label];
            }
            picker.accessoryView = popup;

            if ([picker runModal] != NSAlertFirstButtonReturn) return;

            NSInteger idx = popup.indexOfSelectedItem;
            if (idx >= 0 && idx < (NSInteger)hostEntries.count) {
                NSArray *sel = hostEntries[idx];
                [fields[@"ip"] setStringValue:sel[0]];
                if ([sel[1] length] > 0 && [[fields[@"name"] stringValue] length] == 0)
                    [fields[@"name"] setStringValue:sel[1]];
                if ([sel[2] length] > 0 && ![sel[2] isEqualToString:@"(incomplete)"] && [[fields[@"mac"] stringValue] length] == 0)
                    [fields[@"mac"] setStringValue:sel[2]];
            }
        });
    });
}

- (void)wizardImportSSH:(NSButton *)sender {
    NSWindow *win = objc_getAssociatedObject(sender, &kWindowKey);
    NSDictionary *fields = objc_getAssociatedObject(win, &kFieldsKey);

    NSString *sshResult = [self runDiscover:@[@"import-ssh-config"] timeout:5];
    if (!sshResult || sshResult.length == 0) {
        NSAlert *a = [NSAlert new]; a.messageText = @"No SSH Hosts";
        a.informativeText = @"No hosts found in your SSH configuration file (~/.ssh/config)."; [a runModal]; return;
    }

    NSMutableArray *entries = [NSMutableArray new];
    for (NSString *line in [sshResult componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if (line.length == 0) continue;
        NSArray *parts = [line componentsSeparatedByString:@"|"];
        if (parts.count >= 5) [entries addObject:parts];
    }
    if (entries.count == 0) {
        NSAlert *a = [NSAlert new]; a.messageText = @"No SSH Hosts";
        a.informativeText = @"No usable hosts found in ~/.ssh/config."; [a runModal]; return;
    }

    NSAlert *picker = [NSAlert new];
    picker.messageText = @"Import from SSH Config";
    picker.informativeText = @"Select a host to import:";
    [picker addButtonWithTitle:@"Import"]; [picker addButtonWithTitle:@"Cancel"];

    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 350, 26) pullsDown:NO];
    for (NSArray *e in entries)
        [popup addItemWithTitle:[NSString stringWithFormat:@"%@ -> %@@%@", e[0], e[2], e[1]]];
    picker.accessoryView = popup;

    if ([picker runModal] != NSAlertFirstButtonReturn) return;

    NSInteger idx = popup.indexOfSelectedItem;
    if (idx >= 0 && idx < (NSInteger)entries.count) {
        NSArray *sel = entries[idx];
        if ([[fields[@"name"] stringValue] length] == 0) [fields[@"name"] setStringValue:sel[0]];
        if ([sel[2] length] > 0) [fields[@"user"] setStringValue:sel[2]];
        if ([sel[1] length] > 0) [fields[@"ip"] setStringValue:sel[1]];
        if ([sel[4] length] > 0) [fields[@"key"] setStringValue:sel[4]];
    }
}

- (void)wizardTestConnection:(NSButton *)sender {
    NSWindow *win = objc_getAssociatedObject(sender, &kWindowKey);
    NSDictionary *fields = objc_getAssociatedObject(win, &kFieldsKey);
    NSString *ip = [fields[@"ip"] stringValue];
    NSString *user = [fields[@"user"] stringValue];
    NSString *key = [fields[@"key"] stringValue];

    if (ip.length == 0 || user.length == 0) {
        NSAlert *a = [NSAlert new]; a.messageText = @"Missing Fields";
        a.informativeText = @"Enter the IP address and username first."; [a runModal]; return;
    }

    sender.enabled = NO; sender.title = @"Testing...";

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *expandedKey = [key stringByReplacingOccurrencesOfString:@"~" withString:NSHomeDirectory()];
        NSString *knownHosts = [NSHomeDirectory() stringByAppendingPathComponent:@".config/autofuse/known_hosts"];
        NSTask *t = [NSTask new];
        t.launchPath = @"/usr/bin/ssh";
        t.arguments = @[@"-o", @"ConnectTimeout=5",
                        @"-o", @"StrictHostKeyChecking=accept-new",
                        @"-o", [NSString stringWithFormat:@"UserKnownHostsFile=%@", knownHosts],
                        @"-o", @"BatchMode=yes",
                        @"-i", expandedKey,
                        [NSString stringWithFormat:@"%@@%@", user, ip], @"echo ok"];
        NSPipe *p = [NSPipe pipe]; t.standardOutput = p; t.standardError = [NSPipe pipe];
        BOOL ok = NO;
        @try {
            [t launch]; [t waitUntilExit];
            NSString *out = [[NSString alloc] initWithData:[p.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
            ok = (t.terminationStatus == 0 && [out containsString:@"ok"]);
        } @catch (NSException *e) {}

        dispatch_async(dispatch_get_main_queue(), ^{
            sender.enabled = YES; sender.title = @"Test Connection";
            NSAlert *a = [NSAlert new];
            if (ok) {
                a.messageText = @"Connection Successful";
                a.informativeText = [NSString stringWithFormat:@"Connected to %@@%@ using your SSH key.", user, ip];
                a.alertStyle = NSAlertStyleInformational;
            } else {
                a.messageText = @"Connection Failed";
                a.informativeText = [NSString stringWithFormat:@"Could not connect to %@@%@.\n\nPossible causes:\n- Computer is off or not reachable\n- SSH key not copied to the server yet\n- Wrong username or IP address\n\nTry \"Copy Key to Server\" if you haven't set up key-based login yet.", user, ip];
                a.alertStyle = NSAlertStyleWarning;
            }
            [a runModal];
        });
    });
}

- (void)wizardCopyKeyToServer:(NSButton *)sender {
    NSWindow *win = objc_getAssociatedObject(sender, &kWindowKey);
    NSDictionary *fields = objc_getAssociatedObject(win, &kFieldsKey);
    NSString *ip = [fields[@"ip"] stringValue];
    NSString *user = [fields[@"user"] stringValue];
    NSString *key = [fields[@"key"] stringValue];

    if (ip.length == 0 || user.length == 0) {
        NSAlert *a = [NSAlert new]; a.messageText = @"Missing Fields";
        a.informativeText = @"Enter the IP address and username first."; [a runModal]; return;
    }

    NSString *expandedKey = [key stringByReplacingOccurrencesOfString:@"~" withString:NSHomeDirectory()];
    NSString *pubKey = [expandedKey stringByAppendingString:@".pub"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:pubKey]) {
        NSAlert *a = [NSAlert new]; a.messageText = @"No Public Key";
        a.informativeText = [NSString stringWithFormat:@"Public key not found at %@.\nGo back to Step 2 to generate one.", pubKey];
        a.alertStyle = NSAlertStyleWarning; [a runModal]; return;
    }

    // Use ssh-copy-id in Terminal (interactive, user enters password)
    NSString *cmd = [NSString stringWithFormat:@"ssh-copy-id -i '%@' '%@@%@'", pubKey, user, ip];

    NSAlert *info = [NSAlert new];
    info.messageText = @"Copy Your Key to the Server";
    info.informativeText = [NSString stringWithFormat:
        @"A Terminal window will open and ask for the password on the remote computer.\n\n"
        @"Command:\n%@\n\n"
        @"After entering your password, the key will be installed and you won't need a password again.\n\n"
        @"Note for Windows servers: If ssh-copy-id doesn't work, you may need to manually add your public key. "
        @"For admin users, add it to C:\\ProgramData\\ssh\\administrators_authorized_keys. "
        @"For regular users, add it to C:\\Users\\<username>\\.ssh\\authorized_keys.", cmd];
    [info addButtonWithTitle:@"Open Terminal"]; [info addButtonWithTitle:@"Cancel"];

    if ([info runModal] != NSAlertFirstButtonReturn) return;

    // Launch Terminal with the ssh-copy-id command
    NSString *escapedCmd = [cmd stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escapedCmd = [escapedCmd stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

    NSTask *t = [NSTask new];
    t.launchPath = @"/usr/bin/osascript";
    t.arguments = @[@"-e", [NSString stringWithFormat:@"tell application \"Terminal\" to do script \"%@\"", escapedCmd],
                    @"-e", @"tell application \"Terminal\" to activate"];
    @try { [t launch]; } @catch (NSException *e) {
        // Fallback: just open Terminal
        NSTask *fallback = [NSTask new];
        fallback.launchPath = @"/usr/bin/open";
        fallback.arguments = @[@"-a", @"Terminal"];
        @try { [fallback launch]; } @catch (NSException *e2) {}
    }
}

- (void)wizardDetectDetails:(NSButton *)sender {
    NSWindow *win = objc_getAssociatedObject(sender, &kWindowKey);
    NSDictionary *fields = objc_getAssociatedObject(win, &kFieldsKey);
    NSMutableDictionary *data = objc_getAssociatedObject(win, &kWizardDataKey);
    NSString *ip = [fields[@"ip"] stringValue];
    NSString *user = [fields[@"user"] stringValue];
    NSString *key = [fields[@"key"] stringValue];

    if (ip.length == 0 || user.length == 0) {
        NSAlert *a = [NSAlert new]; a.messageText = @"Missing Fields";
        a.informativeText = @"Enter the IP address and username first."; [a runModal]; return;
    }

    sender.enabled = NO; sender.title = @"Detecting...";

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *args = [NSMutableArray arrayWithObjects:@"probe-host", ip, user, nil];
        if (key.length > 0) [args addObject:key];
        NSString *probeResult = [self runDiscover:args timeout:15];

        dispatch_async(dispatch_get_main_queue(), ^{
            sender.enabled = YES; sender.title = @"Detect Computer Details";

            if (!probeResult || probeResult.length == 0 || [probeResult containsString:@"error:"]) {
                NSAlert *a = [NSAlert new]; a.messageText = @"Detection Failed";
                a.informativeText = [NSString stringWithFormat:@"Could not detect details from %@@%@.\nMake sure you can connect first (test connection or copy your key).", user, ip];
                a.alertStyle = NSAlertStyleWarning; [a runModal]; return;
            }

            NSString *detectedMAC = @"", *detectedHostname = @"";
            NSMutableArray *detectedDisks = [NSMutableArray new];

            for (NSString *line in [probeResult componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
                if (line.length == 0) continue;
                NSArray *kv = [line componentsSeparatedByString:@"\t"];
                if (kv.count < 2) continue;
                if ([kv[0] isEqualToString:@"mac"] && [kv[1] length] > 0) detectedMAC = kv[1];
                else if ([kv[0] isEqualToString:@"hostname"] && [kv[1] length] > 0) detectedHostname = kv[1];
                else if ([kv[0] isEqualToString:@"disk"] && [kv[1] length] > 0) [detectedDisks addObject:kv[1]];
            }

            if (detectedMAC.length > 0) { [fields[@"mac"] setStringValue:detectedMAC]; data[@"wsMAC"] = detectedMAC; }
            if (detectedHostname.length > 0 && [[fields[@"name"] stringValue] length] == 0) {
                [fields[@"name"] setStringValue:detectedHostname]; data[@"wsName"] = detectedHostname;
            }

            if (detectedDisks.count > 0) {
                NSMutableString *diskLines = [NSMutableString new];
                for (NSString *diskEntry in detectedDisks) {
                    NSArray *dp = [diskEntry componentsSeparatedByString:@"|"];
                    if (dp.count >= 1) {
                        NSString *letter = dp[0], *label = dp.count > 1 ? dp[1] : @"";
                        NSString *remotePath;
                        if (letter.length == 1 && [[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:[letter characterAtIndex:0]]) {
                            remotePath = [NSString stringWithFormat:@"/%@:/", letter];
                        } else {
                            remotePath = letter;
                            letter = [letter lastPathComponent];
                            if (letter.length == 0) letter = @"root";
                        }
                        if (label.length == 0) label = letter;
                        NSString *sizeInfo = @"";
                        if (dp.count >= 4) sizeInfo = [NSString stringWithFormat:@"  (%@/%@)", dp[2], dp[3]];
                        [diskLines appendFormat:@"%@, %@, %@%@\n", letter, label, remotePath, sizeInfo];
                    }
                }
                [fields[@"disks"] setString:diskLines];
                data[@"wsDisks"] = diskLines;
            }

            NSMutableString *summary = [NSMutableString stringWithString:@"Detected:\n"];
            if (detectedHostname.length > 0) [summary appendFormat:@"  Name: %@\n", detectedHostname];
            if (detectedMAC.length > 0) [summary appendFormat:@"  MAC: %@\n", detectedMAC];
            [summary appendFormat:@"  Disks: %ld found", (long)detectedDisks.count];

            NSAlert *a = [NSAlert new];
            a.messageText = @"Computer Details Detected";
            a.informativeText = summary;
            a.alertStyle = NSAlertStyleInformational;
            [a runModal];
        });
    });
}

- (void)wizardSaveAndNext:(NSButton *)sender {
    NSWindow *win = objc_getAssociatedObject(sender, &kWindowKey);
    NSDictionary *fields = objc_getAssociatedObject(win, &kFieldsKey);
    NSMutableDictionary *data = objc_getAssociatedObject(win, &kWizardDataKey);

    NSString *ip = [fields[@"ip"] stringValue];
    NSString *user = [fields[@"user"] stringValue];
    NSString *key = [fields[@"key"] stringValue];
    NSString *name = [fields[@"name"] stringValue];
    NSString *mac = [fields[@"mac"] stringValue];
    NSString *disksRaw = [fields[@"disks"] string];

    if (ip.length == 0 || user.length == 0) {
        NSAlert *a = [NSAlert new]; a.messageText = @"Missing Fields";
        a.informativeText = @"IP Address and Username are required to continue."; [a runModal]; return;
    }
    if (name.length == 0) name = ip;

    // Parse disks
    NSMutableArray *disksArray = [NSMutableArray new];
    for (NSString *line in [disksRaw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length == 0) continue;
        NSArray *parts = [trimmed componentsSeparatedByString:@","]; if (parts.count < 3) continue;
        NSString *letter = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *label = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *rpath = [parts[2] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        // Strip size info in parentheses if present
        NSRange parenRange = [rpath rangeOfString:@"  ("];
        if (parenRange.location != NSNotFound) rpath = [rpath substringToIndex:parenRange.location];
        [disksArray addObject:@{@"letter": letter, @"label": label, @"remote_path": rpath}];
    }

    if (disksArray.count == 0) {
        NSAlert *a = [NSAlert new]; a.messageText = @"No Disks";
        a.informativeText = @"Add at least one remote disk to connect."; [a runModal]; return;
    }

    // Save workstation to config
    NSMutableDictionary *ws = [NSMutableDictionary dictionaryWithDictionary:@{
        @"name": name, @"user": user, @"lan_ip": ip, @"vpn_ip": @"",
        @"ssh_key": key, @"disks": disksArray
    }];
    if (mac.length > 0) ws[@"mac_address"] = mac;

    NSMutableDictionary *cfg = [self loadConfig];
    if (!cfg) {
        cfg = [NSMutableDictionary dictionaryWithDictionary:@{
            @"workstations": [NSMutableArray new], @"mount_base": @"~/workstation",
            @"ssh_options": @{@"cipher": @"aes128-gcm@openssh.com", @"compression": @NO, @"keepalive_interval": @15, @"keepalive_count": @3},
            @"cache_options": @{@"cache_timeout": @115200, @"attr_timeout": @115200, @"entry_timeout": @115200, @"kernel_cache": @YES, @"auto_cache": @YES},
            @"io_options": @{@"iosize": @1048576, @"max_write": @65536, @"noappledouble": @YES, @"noapplexattr": @YES, @"defer_permissions": @YES}
        }];
    }

    NSMutableArray *workstations = cfg[@"workstations"];
    // Check for duplicate
    BOOL found = NO;
    for (NSUInteger i = 0; i < workstations.count; i++) {
        if ([workstations[i][@"name"] isEqualToString:name]) {
            workstations[i] = ws; found = YES; break;
        }
    }
    if (!found) [workstations addObject:ws];

    if (![self saveConfig:cfg]) {
        NSAlert *a = [NSAlert new]; a.messageText = @"Save Failed";
        a.informativeText = @"Could not save the configuration."; [a runModal]; return;
    }

    // Update wizard data for summary
    data[@"wsName"] = name;
    data[@"wsIP"] = ip;
    data[@"wsUser"] = user;
    data[@"wsMAC"] = mac;
    data[@"wsDisks"] = disksRaw;

    // Reload hosts
    [self loadHosts]; [self refreshStatus]; [self buildMenu];

    [self wizardShowStep:4 inWindow:win];
}

- (void)wizardSkipToFinish:(NSButton *)sender {
    NSWindow *win = objc_getAssociatedObject(sender, &kWindowKey);
    NSMutableDictionary *data = objc_getAssociatedObject(win, &kWizardDataKey);
    data[@"wsName"] = @"";
    data[@"wsIP"] = @"";
    [self wizardShowStep:4 inWindow:win];
}

// ─── Step 4: Done ──────────────────────────────────────────────────────────

- (void)wizardBuildStep4:(NSWindow *)win {
    NSView *cv = win.contentView;
    NSMutableDictionary *data = objc_getAssociatedObject(win, &kWizardDataKey);
    CGFloat W = cv.frame.size.width;
    CGFloat H = cv.frame.size.height;

    // Fixed top area
    CGFloat topY = H - 30;
    NSTextField *stepLabel = [self makeLabel:@"Step 4 of 4" frame:NSMakeRect(20, topY, W-40, 16)];
    stepLabel.font = [NSFont systemFontOfSize:11];
    stepLabel.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:stepLabel]; topY -= 26;

    NSTextField *title = [self makeLabel:@"All Set!" frame:NSMakeRect(20, topY, W-40, 28)];
    title.font = [NSFont boldSystemFontOfSize:22];
    [cv addSubview:title];

    // Fixed bottom buttons
    CGFloat btnY = 20;
    BOOL hasWS = [data[@"wsName"] length] > 0;
    if (hasWS) {
        NSButton *mountBtn = [[NSButton alloc] initWithFrame:NSMakeRect(20, btnY, 140, 32)];
        mountBtn.title = @"Connect Disks Now"; mountBtn.bezelStyle = NSBezelStyleRounded;
        mountBtn.target = self; mountBtn.action = @selector(wizardMountNow:);
        objc_setAssociatedObject(mountBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
        [cv addSubview:mountBtn];
    }

    NSButton *closeBtn = [[NSButton alloc] initWithFrame:NSMakeRect(W-120, btnY, 80, 32)];
    closeBtn.title = @"Close"; closeBtn.bezelStyle = NSBezelStyleRounded;
    closeBtn.keyEquivalent = @"\r";
    closeBtn.target = self; closeBtn.action = @selector(wizardClose:);
    objc_setAssociatedObject(closeBtn, &kWindowKey, win, OBJC_ASSOCIATION_ASSIGN);
    [cv addSubview:closeBtn];

    // Scrollable middle area
    CGFloat scrollTop = topY - 30;
    CGFloat scrollBottom = btnY + 44;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:
        NSMakeRect(0, scrollBottom, W, scrollTop - scrollBottom)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;

    CGFloat contentHeight = 400;
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, contentHeight)];
    CGFloat y = contentHeight - 10;

    NSImage *checkImg = [self sfSymbol:@"checkmark.seal.fill" size:48 color:[NSColor systemGreenColor]];
    NSImageView *checkView = [[NSImageView alloc] initWithFrame:NSMakeRect(260, y - 56, 56, 56)];
    checkView.image = checkImg;
    [content addSubview:checkView]; y -= 70;

    NSTextField *summaryTitle = [self makeLabel:@"Setup Summary" frame:NSMakeRect(20, y - 20, W-40, 20)];
    summaryTitle.font = [NSFont boldSystemFontOfSize:14];
    [content addSubview:summaryTitle]; y -= 28;

    // FUSE backend
    NSString *backendStr = [data[@"fuseBackend"] length] > 0 ? data[@"fuseBackend"] : @"(not checked)";
    NSTextField *fuseLine = [self makeLabel:[NSString stringWithFormat:@"Remote disk software:  %@", backendStr]
                                      frame:NSMakeRect(30, y - 18, 530, 18)];
    fuseLine.font = [NSFont systemFontOfSize:12];
    [content addSubview:fuseLine]; y -= 22;

    // SSH Key
    NSString *keyStr = data[@"sshKeyPath"] ?: @"~/.ssh/id_ed25519";
    NSTextField *keyLine = [self makeLabel:[NSString stringWithFormat:@"Secure login key:  %@", keyStr]
                                     frame:NSMakeRect(30, y - 18, 530, 18)];
    keyLine.font = [NSFont systemFontOfSize:12];
    [content addSubview:keyLine]; y -= 22;

    // Workstation
    if (hasWS) {
        NSTextField *wsLine = [self makeLabel:[NSString stringWithFormat:@"Remote computer:  %@ (%@)", data[@"wsName"], data[@"wsIP"]]
                                        frame:NSMakeRect(30, y - 18, 530, 18)];
        wsLine.font = [NSFont systemFontOfSize:12];
        [content addSubview:wsLine]; y -= 22;

        // Show disk summary
        NSString *disksRaw = data[@"wsDisks"] ?: @"";
        NSMutableArray *diskNames = [NSMutableArray new];
        for (NSString *line in [disksRaw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (trimmed.length == 0) continue;
            NSArray *parts = [trimmed componentsSeparatedByString:@","];
            if (parts.count >= 2) {
                NSString *letter = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                NSString *label = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                [diskNames addObject:[NSString stringWithFormat:@"%@ (%@)", letter, label]];
            }
        }
        if (diskNames.count > 0) {
            NSTextField *disksLine = [self makeLabel:[NSString stringWithFormat:@"Disks:  %@", [diskNames componentsJoinedByString:@", "]]
                                               frame:NSMakeRect(30, y - 18, 530, 18)];
            disksLine.font = [NSFont systemFontOfSize:12];
            [content addSubview:disksLine]; y -= 22;
        }
    } else {
        NSTextField *noWS = [self makeLabel:@"Remote computer:  (none configured — use \"Add Workstation\" from the menu bar)"
                                      frame:NSMakeRect(30, y - 18, 530, 18)];
        noWS.font = [NSFont systemFontOfSize:12];
        noWS.textColor = [NSColor secondaryLabelColor];
        [content addSubview:noWS]; y -= 22;
    }

    y -= 20;

    NSTextField *tipTitle = [self makeLabel:@"What's Next?" frame:NSMakeRect(20, y - 20, W-40, 20)];
    tipTitle.font = [NSFont boldSystemFontOfSize:13];
    [content addSubview:tipTitle]; y -= 24;

    NSTextField *tip1 = [self makeLabel:@"AutoFuse lives in your menu bar. Click the disk icon to connect remote disks, wake computers, and more."
                                  frame:NSMakeRect(30, y - 32, 530, 32)];
    tip1.font = [NSFont systemFontOfSize:12];
    tip1.textColor = [NSColor secondaryLabelColor];
    [content addSubview:tip1]; y -= 36;

    NSTextField *tip2 = [self makeLabel:@"You can add more computers anytime with \"Add Workstation...\" from the menu."
                                  frame:NSMakeRect(30, y - 18, 530, 18)];
    tip2.font = [NSFont systemFontOfSize:12];
    tip2.textColor = [NSColor secondaryLabelColor];
    [content addSubview:tip2];

    scroll.documentView = content;
    [content scrollPoint:NSMakePoint(0, contentHeight)];
    [cv addSubview:scroll];
}

- (void)wizardMountNow:(NSButton *)sender {
    NSWindow *win = objc_getAssociatedObject(sender, &kWindowKey);
    NSMutableDictionary *data = objc_getAssociatedObject(win, &kWizardDataKey);
    NSString *wsName = data[@"wsName"];

    if (wsName.length > 0) {
        [self _asyncOp:@"Mount All" args:@[@"mount", wsName] timeout:120];
    }
    [win close];
    self.wizardWindow = nil;
}

- (void)wizardClose:(NSButton *)sender {
    NSWindow *win = objc_getAssociatedObject(sender, &kWindowKey);
    [win close];
    self.wizardWindow = nil;
}

// ─── Wizard Navigation Helpers ─────────────────────────────────────────────

- (void)wizardNext:(NSButton *)sender {
    NSWindow *win = objc_getAssociatedObject(sender, &kWindowKey);
    NSNumber *stepNum = objc_getAssociatedObject(win, &kWizardStepKey);
    NSInteger step = stepNum.integerValue + 1;
    if (step > 4) step = 4;
    [self wizardShowStep:step inWindow:win];
}

- (void)wizardBack:(NSButton *)sender {
    NSWindow *win = objc_getAssociatedObject(sender, &kWindowKey);
    NSNumber *stepNum = objc_getAssociatedObject(win, &kWizardStepKey);
    NSInteger step = stepNum.integerValue - 1;
    if (step < 1) step = 1;

    // Save step 3 field values before going back
    if (stepNum.integerValue == 3) {
        NSDictionary *fields = objc_getAssociatedObject(win, &kFieldsKey);
        NSMutableDictionary *data = objc_getAssociatedObject(win, &kWizardDataKey);
        if (fields && data) {
            data[@"wsIP"] = [fields[@"ip"] stringValue] ?: @"";
            data[@"wsUser"] = [fields[@"user"] stringValue] ?: @"";
            data[@"wsName"] = [fields[@"name"] stringValue] ?: @"";
            data[@"wsMAC"] = [fields[@"mac"] stringValue] ?: @"";
            data[@"wsDisks"] = [fields[@"disks"] string] ?: @"";
            data[@"sshKeyPath"] = [fields[@"key"] stringValue] ?: @"~/.ssh/id_ed25519";
        }
    }

    [self wizardShowStep:step inWindow:win];
}

// ─── First-Run Detection ──────────────────────────────────────────────────

- (BOOL)shouldShowSetupWizardOnFirstRun {
    // Show wizard if no workstations configured AND no FUSE backend detected
    if (self.hosts.count > 0) return NO;
    NSString *depsResult = [self runScript:@[@"check-deps"]];
    if ([depsResult containsString:@"ok:sshfs:"]) return NO;
    return YES;
}

// ─── Auto-Heal Timer ────────────────────────────────────────────────────────

// Periodic check (interval configurable in Preferences, default 120s) that
// looks for stale mounts and attempts to recover them. Runs on LOW-priority
// global queue so a hung sshfs won't starve the UI. Strategy:
//   1. `status-all` emits one line per disk. If none mentions "stale",
//      there's nothing to do — cheap, fast, no side effects.
//   2. If any line mentions "stale", run `heal-all` (which individually
//      kill-unmount-remounts each stale disk) with a long 90s timeout —
//      remounts can take 30-60s each when the server just came back online.
//   3. On return to main thread, refresh UI state and surface a user
//      notification so they know recovery happened even if they weren't
//      watching the menu bar.
// Exponential backoff constants. Base matches the default heal timer tick
// (first retry as soon as the next poll fires). Max caps the back-off so a
// recovered workstation doesn't wait 2 hours before we try again.
#define HEAL_BACKOFF_BASE_SEC 120
#define HEAL_BACKOFF_MAX_SEC  1800
#define HEAL_BACKOFF_KEY(ws, disk) [NSString stringWithFormat:@"%@/%@", (ws), (disk)]

// Compute the current backoff interval in seconds for a given ws/disk key.
// Interval = base * 2^failures, saturated at max. 0 failures → base (120s).
- (NSTimeInterval)healBackoffFor:(NSString *)key {
    NSNumber *fails = self.healFailCount[key];
    NSInteger n = fails.integerValue;
    if (n <= 0) return HEAL_BACKOFF_BASE_SEC;
    // 2^n with saturation; cap exponent at 5 to avoid overflow and because
    // 120 * 2^5 = 3840 already exceeds max (1800).
    if (n > 5) n = 5;
    NSTimeInterval interval = HEAL_BACKOFF_BASE_SEC * (1L << n);
    return interval > HEAL_BACKOFF_MAX_SEC ? HEAL_BACKOFF_MAX_SEC : interval;
}

- (void)autoHealCheck:(NSTimer *)timer {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSString *out = [self runScript:@[@"status-all"] timeout:10];
        // A timed-out status-all yields zero stale lines, which would wrongly
        // clear all backoff state and resume hammering a broken host. Skip.
        if ([out isEqualToString:@"timeout"]) return;

        // Parse stale disks from status-all output.
        // Format per line: ws|letter|state:mountpoint
        NSMutableArray<NSArray *> *staleDisks = [NSMutableArray new];
        for (NSString *line in [out componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSArray *parts = [line componentsSeparatedByString:@"|"];
            if (parts.count < 3) continue;
            NSString *stateField = [parts[2] componentsSeparatedByString:@":"].firstObject;
            if (![stateField isEqualToString:@"stale"]) continue;
            [staleDisks addObject:@[parts[0], parts[1]]];
        }

        if (staleDisks.count == 0) {
            // Nothing stale anywhere — clear all backoff state so a future
            // failure starts at the base interval, not the escalated one.
            @synchronized(self.healFailCount) {
                [self.healFailCount removeAllObjects];
                [self.healLastAttempt removeAllObjects];
            }
            return;
        }

        // For each stale disk: if past its backoff window, attempt heal.
        NSDate *now = [NSDate date];
        NSInteger attempted = 0, recovered = 0;
        for (NSArray *pair in staleDisks) {
            NSString *ws = pair[0], *letter = pair[1];
            NSString *key = HEAL_BACKOFF_KEY(ws, letter);
            @synchronized(self.healFailCount) {
                NSDate *last = self.healLastAttempt[key];
                NSTimeInterval backoff = [self healBackoffFor:key];
                if (last != nil && [now timeIntervalSinceDate:last] < backoff) {
                    continue; // still within backoff window
                }
                // Claim the slot BEFORE the up-to-90s heal so an overlapping
                // pass sees it within-window and skips, instead of both passing
                // the check and launching concurrent heals on the same disk.
                self.healLastAttempt[key] = now;
            }

            attempted++;
            NSString *result = [self runScript:@[@"heal", ws, letter] timeout:90];
            BOOL healed = [result containsString:@"mounted"];
            @synchronized(self.healFailCount) {
                if (healed) {
                    [self.healFailCount removeObjectForKey:key];
                    recovered++;
                } else {
                    NSInteger prev = [self.healFailCount[key] integerValue];
                    self.healFailCount[key] = @(prev + 1);
                }
            }
        }

        if (attempted > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self refreshStatus];
                [self buildMenu];
                NSString *body = (recovered == attempted)
                    ? [NSString stringWithFormat:@"Recovered %ld stale mount%@",
                        (long)recovered, recovered == 1 ? @"" : @"s"]
                    : [NSString stringWithFormat:@"Attempted %ld, recovered %ld (others backing off)",
                        (long)attempted, (long)recovered];
                [self postNotificationWithTitle:@"Auto-Heal" body:body];
            });
        }
    });
}

// ─── NSMenuDelegate ─────────────────────────────────────────────────────────

// Open the menu with the last-known state immediately, then refresh in the
// background. Blocking here (the pre-fix behavior) would stall the dropdown
// for 2–6 seconds whenever network latency is high — the user experiences
// the menu bar as "frozen". The pollTimer keeps state fresh between opens,
// so the cached state shown in buildMenu is almost always current; when it
// isn't, the async refresh below rebuilds once the fresh data arrives.
- (void)menuWillOpen:(NSMenu *)menu {
    // Render immediately from cached state
    [self buildMenu];

    // Refresh asynchronously; rebuild unconditionally when it completes.
    // NSMenu has no `isVisible` property (that's NSWindow), and buildMenu
    // is cheap (~20ms) so always-rebuild is fine even if the user has
    // already closed the menu.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self refreshStatus];
        [self refreshVPNStatus];   // event-driven VPN refresh (replaces per-poll)
        dispatch_async(dispatch_get_main_queue(), ^{
            [self buildMenu];
        });
    });
}

// ─── UNUserNotificationCenterDelegate ──────────────────────────────────────

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

// ─── Network Change Observer (with debounce) ───────────────────────────────

// Wired to a CFNotificationCenter Darwin-notify observer (see
// `networkChangeCallback` below). Darwin fires this multiple times in quick
// succession when WiFi disconnects, reconnects, or the interface flaps —
// we debounce to 5 seconds so we only run one recovery pass per "event".
// The 5s delay also lets the kernel's route table and DNS settle before
// we start pinging; too-early probes return stale "unreachable" results.
- (void)networkChanged:(NSNotification *)note {
    // Debounce: cancel previous scheduled heal, schedule new one after 5s (#8)
    if (self.networkDebounceTimer) {
        [self.networkDebounceTimer invalidate];
        self.networkDebounceTimer = nil;
    }
    self.networkDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
        target:self selector:@selector(_debouncedNetworkHeal:) userInfo:nil repeats:NO];
}

// Runs 5s after the last network event. The critical behavior here is
// "no-reachable-hosts → panic-unmount-all" BEFORE any Finder/app tries to
// `stat()` a mount point. Without this, Finder freezes when the network
// drops with mounted sshfs — the kernel waits forever for packets that
// will never arrive, and the beachball spreads to every process that
// touches the file system (Spotlight, Terminal, Dock).
- (void)_debouncedNetworkHeal:(NSTimer *)timer {
    self.networkDebounceTimer = nil;
    [self refreshVPNStatus];   // network topology just changed — refresh VPN state

    // CRITICAL: check if ANY workstation is still reachable. If none, trigger panic-unmount
    // BEFORE any app touches the mount path and hangs.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        BOOL hasMountedDisks = NO;
        for (WSHost *h in self.hosts)
            for (WSDisk *d in h.disks)
                if ([d.status isEqualToString:@"mounted"]) hasMountedDisks = YES;

        if (hasMountedDisks) {
            // Ping each workstation IP quickly (1s timeout) to detect network loss
            BOOL anyReachable = NO;
            for (WSHost *h in self.hosts) {
                NSString *ip = h.lanIP.length > 0 ? h.lanIP : h.vpnIP;
                if (ip.length == 0) continue;
                NSTask *t = [NSTask new];
                t.launchPath = @"/sbin/ping";
                t.arguments = @[@"-c", @"1", @"-t", @"1", @"-W", @"1000", ip];
                t.standardOutput = [NSPipe pipe];
                t.standardError = [NSPipe pipe];
                @try {
                    [t launch];
                    [t waitUntilExit];
                    if (t.terminationStatus == 0) { anyReachable = YES; break; }
                } @catch (NSException *e) {}
            }

            if (!anyReachable) {
                // NETWORK IS GONE — emergency panic unmount to prevent Finder hang
                [self runScript:@[@"panic-unmount-all"] timeout:15];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self refreshStatus]; [self buildMenu];
                    [self postNotificationWithTitle:@"Network Lost"
                                               body:@"Disconnected remote disks to prevent system freeze. They will reconnect when network returns."];
                });
                return;
            }
        }

        // Network is OK. The panic-unmount above is a safety mechanism that
        // always runs; auto-heal (remount) is OPTIONAL and gated by the user's
        // "Auto-Heal on Network Change" preference — read in the UI but, until
        // now, never actually honored here.
        NSDictionary *netCfg = [self loadConfig];
        BOOL healOnNet = netCfg[@"heal_on_network_change"] ? [netCfg[@"heal_on_network_change"] boolValue] : YES;
        if (!healOnNet) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self refreshStatus]; [self buildMenu]; });
            return;
        }

        // Normal stale detection + heal
        [self runScript:@[@"panic-check"] timeout:15];  // force-clean any stale
        BOOL hasStale = NO;
        for (WSHost *h in self.hosts)
            for (WSDisk *d in h.disks)
                if ([d.status isEqualToString:@"stale"]) hasStale = YES;
        if (hasStale) {
            [self runScript:@[@"heal-all"] timeout:90];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self refreshStatus]; [self buildMenu];
                [self postNotificationWithTitle:@"Connections Restored"
                                           body:@"Reconnected remote disks after network change."];
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self refreshStatus]; [self buildMenu];
            });
        }
    });
}

// ─── Sleep/Wake Handling ───────────────────────────────────────────────────

- (void)systemDidWake:(NSNotification *)note {
    // Recreate timers on wake with fresh config + adaptive cadence (#9).
    [self applyTimerCadence:YES];

    // Immediate authoritative refresh, then right-size cadence to it.
    [self refreshStatus];
    [self refreshVPNStatus];   // event-driven VPN refresh (replaces per-poll)
    [self buildMenu];
    [self applyTimerCadence:NO];

    // Delayed heal after 3s to allow network to come up (#5)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self refreshStatus];
        [self buildMenu];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            BOOL hasStale = NO;
            for (WSHost *h in self.hosts)
                for (WSDisk *d in h.disks)
                    if ([d.status isEqualToString:@"stale"]) hasStale = YES;
            if (hasStale) {
                [self runScript:@[@"heal-all"] timeout:90];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self refreshStatus]; [self buildMenu];
                    [self postNotificationWithTitle:@"Wake Recovery" body:@"Stale mounts recovered after system wake"];
                });
            }
        });
    });
}

// ─── Dependency Check ──────────────────────────────────────────────────────

- (void)checkDependencies {
    NSString *result = [self runScript:@[@"check-deps"]];
    if ([result containsString:@"sshfs_not_found"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *a = [NSAlert new];
            a.messageText = @"sshfs Not Found";
            a.informativeText = @"AutoFuse requires sshfs and macFUSE to function.\n\n"
                                @"Install macFUSE from: https://osxfuse.github.io\n"
                                @"Then install sshfs via Homebrew:\n"
                                @"  brew install sshfs\n\n"
                                @"The app will continue to run but mounts will fail.";
            a.alertStyle = NSAlertStyleCritical;
            [a addButtonWithTitle:@"OK"];
            [a addButtonWithTitle:@"Open macFUSE Website"];
            NSModalResponse resp = [a runModal];
            if (resp == NSAlertSecondButtonReturn) {
                [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://osxfuse.github.io"]];
            }
        });
    }
    self.dependenciesChecked = YES;
}

// ─── Lifecycle ──────────────────────────────────────────────────────────────

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSString *bundleScript = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"mount.sh"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:bundleScript]) {
        self.scriptPath = bundleScript;
    } else {
        NSString *dir = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
        self.scriptPath = [dir stringByAppendingPathComponent:@"mount.sh"];
    }

    // Discover script: same directory as mount.sh
    NSString *bundleDiscover = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"discover.sh"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:bundleDiscover]) {
        self.discoverPath = bundleDiscover;
    } else {
        NSString *dir = [self.scriptPath stringByDeletingLastPathComponent];
        self.discoverPath = [dir stringByAppendingPathComponent:@"discover.sh"];
    }

    self.configPath = [self resolveConfigPath];
    self.operationCount = 0;
    self.vpnStatus = @"";
    self.healFailCount = [NSMutableDictionary new];
    self.healLastAttempt = [NSMutableDictionary new];

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *initialIcon = [self sfSymbol:@"externaldrive" size:14 color:nil];
    if (initialIcon) {
        [initialIcon setTemplate:YES];
        self.statusItem.button.image = initialIcon;
    } else {
        self.statusItem.button.title = @"🖥";
    }

    // Check login item status
    self.startsAtLogin = (SMAppService.mainAppService.status == SMAppServiceStatusEnabled);

    // Request notification permissions (#11)
    UNUserNotificationCenter *nc = [UNUserNotificationCenter currentNotificationCenter];
    nc.delegate = self;
    [nc requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                      completionHandler:^(BOOL granted, NSError *error) {}];

#if SPARKLE_AVAILABLE
    // Initialize Sparkle updater
    self.updaterController = [[SPUStandardUpdaterController alloc] initWithStartingDelay:5 updaterDelegate:nil];
#endif

    [self loadHosts];
    [self refreshStatus];
    [self refreshVPNStatus];
    [self drainEndpointEvents];
    [self buildMenu];

    // First-run: show setup wizard if no workstations and no FUSE backend
    // Otherwise just check dependencies as before (#12)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL showWizard = [self shouldShowSetupWizardOnFirstRun];
        if (showWizard) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showSetupWizard:nil];
            });
        } else {
            [self checkDependencies];
        }
    });

    // Read settings from config
    NSMutableDictionary *launchCfg = [self loadConfig];
    self.showLatency = [launchCfg[@"show_latency"] boolValue];
    // Poll + auto-heal timers via the single adaptive-cadence scheduler
    // (energy #3/#4/#5). State is already authoritative here (refreshStatus
    // ran above), so the initial multiplier is correct.
    [self applyTimerCadence:YES];

    // Watch for network changes
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(networkChanged:)
        name:@"com.apple.system.config.network_change" object:nil];

    // Also watch via CFNotification for broader coverage
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)(self),
        networkChangeCallback, CFSTR("com.apple.system.config.network_change"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    // Register for sleep/wake notifications (#5)
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
        selector:@selector(systemDidWake:)
        name:NSWorkspaceDidWakeNotification object:nil];
}

// Return the interface (e.g. "en0", "utun6") that packets to the given
// endpoint would egress through, or nil if `route` can't resolve it
// within the 2s timeout. Used to enrich endpoint-switch notifications
// with context like "via en0 LAN" or "via utun-ts Tailscale" — turns a
// bare IP change into a meaningful "you're now on Wi-Fi vs VPN" signal.
//
// Timeout is mandatory: `route get` normally returns in <10ms, but during
// a concurrent network flap (SCNetworkReachability rebuilding) it can
// stall. Without a bound, this helper would block its caller forever.
// Uses the same dispatch_semaphore pattern as runScript: for consistency.
- (NSString *)interfaceForEndpoint:(NSString *)ep {
    if (ep.length == 0) return nil;
    NSTask *t = [NSTask new];
    t.launchPath = @"/sbin/route";
    t.arguments = @[@"-n", @"get", ep];
    NSPipe *outPipe = [NSPipe pipe];
    t.standardOutput = outPipe;
    t.standardError = [NSPipe pipe];
    __block NSData *outData = nil;
    NSString *result = nil;
    @try {
        [t launch];
        dispatch_group_t readGroup = dispatch_group_create();
        dispatch_group_enter(readGroup);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            outData = [outPipe.fileHandleForReading readDataToEndOfFile];
            dispatch_group_leave(readGroup);
        });
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [t waitUntilExit];
            dispatch_semaphore_signal(sem);
        });
        long timedOut = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        if (timedOut != 0) {
            [t terminate];
            [outPipe.fileHandleForReading closeFile];
            return nil;
        }
        dispatch_group_wait(readGroup, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC));
        NSString *out = [[NSString alloc] initWithData:outData ?: [NSData data] encoding:NSUTF8StringEncoding] ?: @"";
        for (NSString *line in [out componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([trimmed hasPrefix:@"interface:"]) {
                NSRange colon = [trimmed rangeOfString:@":"];
                if (colon.location != NSNotFound) {
                    result = [[trimmed substringFromIndex:colon.location + 1]
                              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    break;
                }
            }
        }
    } @catch (NSException *e) {}
    return result.length > 0 ? result : nil;
}

// Consume endpoint-switch events dropped by `_pick_endpoint` in mount.sh.
// Each event file lives at ~/.config/autofuse/.events/switch-<ts>-<pid>
// and holds tab-separated `<ws>\t<old>\t<new>\t<ts>`. We delete the file
// first (even when malformed) to prevent a single bad event from poisoning
// subsequent drains. Events older than 5 minutes are silently discarded —
// typically they mean the app was closed while mount.sh ran, and surfacing
// stale "X reconnected" popups at app launch would be noise.
//
// Notification body includes the route interface for the NEW endpoint only
// (e.g. "via en0") because that's the live, verifiable context. The OLD
// endpoint may no longer be routable — querying `route get` on a dead IP
// can return stale or default-route info and mislead the user.
//
// Runs on a background queue because `interfaceForEndpoint:` shells out to
// `/sbin/route` (10-50ms normally, multi-second during network flaps).
// Called synchronously from `pollStatus` on the main NSTimer queue — doing
// the route lookups inline would stall the menu bar UI once per poll.
// Notification posting is dispatched back to main because UNNotification-
// Center APIs must be called on the main thread.
- (void)drainEndpointEvents {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSString *eventsDir = [NSHomeDirectory() stringByAppendingPathComponent:@".config/autofuse/.events"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:eventsDir error:nil];
        if (files.count == 0) return;
        NSTimeInterval nowEpoch = [[NSDate date] timeIntervalSince1970];
        for (NSString *f in files) {
            if (![f hasPrefix:@"switch-"]) continue;
            NSString *path = [eventsDir stringByAppendingPathComponent:f];
            NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            [fm removeItemAtPath:path error:nil];
            if (content.length == 0) continue;
            NSString *trimmed = [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSArray *parts = [trimmed componentsSeparatedByString:@"\t"];
            if (parts.count < 4) continue;
            NSString *ws = parts[0];
            NSString *oldEp = parts[1];
            NSString *newEp = parts[2];
            NSTimeInterval eventEpoch = [parts[3] doubleValue];
            if (nowEpoch - eventEpoch > 300) continue;

            NSString *newIface = [self interfaceForEndpoint:newEp];
            NSString *newLabel = newIface.length > 0
                ? [NSString stringWithFormat:@"%@ via %@", newEp, newIface]
                : newEp;

            NSString *title = [NSString stringWithFormat:@"%@ reconnected", ws];
            NSString *body = oldEp.length > 0
                ? [NSString stringWithFormat:@"Switched to %@ (was %@)", newLabel, oldEp]
                : [NSString stringWithFormat:@"Connected via %@", newLabel];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self postNotificationWithTitle:title body:body];
            });
        }
    });
}

// ─── Adaptive Timer Cadence (energy) ───────────────────────────────────────
// Single source of truth for (re)scheduling the poll + heal timers, replacing
// the three copy-pasted scheduling blocks (launch / preferences / wake).
//
// Why: a fixed 30s poll that wakes the CPU 24/7 regardless of state is the
// app's main idle-energy cost. We stretch the cadence when there is nothing
// urgent to watch and add timer tolerance so macOS can coalesce our wakeups
// with other timers (a real power win for periodic timers).
//
//   stale present            → ×1   (poll fast: we want to catch recovery)
//   all mounts healthy       → ×2
//   nothing mounted          → ×3   (just watching for out-of-band changes)
//   Low Power Mode (battery) → additional ×2 on top of the above
//
// pollStatus re-evaluates every tick and reschedules only when the multiplier
// actually changes (no churn); launch/preferences/wake force a base reload.

// Current set of kernel mount points (getmntinfo, MNT_NOWAIT). Reads the
// kernel's cached mount table — no subprocess, no network, never blocks.
- (NSSet<NSString *> *)mountedPaths {
    struct statfs *mnts = NULL;
    int n = getmntinfo(&mnts, MNT_NOWAIT);
    if (n <= 0) return [NSSet set];
    NSMutableSet<NSString *> *set = [NSMutableSet setWithCapacity:(NSUInteger)n];
    for (int i = 0; i < n; i++) {
        [set addObject:[NSString stringWithUTF8String:mnts[i].f_mntonname]];
    }
    return set;
}

// Subprocess-free status refresh for the frequent poll timer. Decides
// mounted/unmounted per disk by matching each disk's already-known mount point
// against the live kernel mount table — no bash `status-all` fan-out, no ssh,
// no network `ls`. Stale detection (mounted-but-server-dead) stays with the
// heal timer's authoritative bash `status-all`, which keeps the timeout-
// protected liveness probe; a previously-flagged 'stale' is preserved here so
// the warning icon doesn't flicker between heal passes. Disks believed
// unmounted are left untouched (an out-of-band CLI mount is picked up by the
// next authoritative refresh on the heal interval).
- (void)refreshStatusFast {
    NSSet<NSString *> *mounted = [self mountedPaths];
    for (WSHost *h in self.hosts) {
        for (WSDisk *d in h.disks) {
            if (d.mountPoint.length == 0) continue;          // believed unmounted
            if ([mounted containsObject:d.mountPoint]) {
                if (![d.status isEqualToString:@"stale"]) d.status = @"mounted";
            } else {
                d.status = @"unmounted";
                d.mountPoint = @"";
            }
        }
    }
    [self updateIcon];
}

// Cadence multiplier from current mount state + power source. See header above.
- (double)cadenceMultiplier {
    BOOL anyMounted = NO, anyStale = NO;
    for (WSHost *h in self.hosts) {
        for (WSDisk *d in h.disks) {
            if ([d.status isEqualToString:@"mounted"]) anyMounted = YES;
            else if ([d.status isEqualToString:@"stale"]) anyStale = YES;
        }
    }
    double mult;
    if (anyStale)         mult = 1.0;   // something broken — poll fast
    else if (!anyMounted) mult = 3.0;   // nothing to keep warm
    else                  mult = 2.0;   // steady, healthy
    if (NSProcessInfo.processInfo.lowPowerModeEnabled) mult *= 2.0;
    return mult;
}

// (Re)schedule poll + heal timers. reloadBase=YES re-reads the base intervals
// from config (launch / preferences / wake); reloadBase=NO reuses the cached
// base and reschedules only when the cadence multiplier changed.
- (void)applyTimerCadence:(BOOL)reloadBase {
    if (reloadBase) {
        NSMutableDictionary *cfg = [self loadConfig];
        NSInteger p  = [cfg[@"poll_interval"] integerValue];
        self.basePollSec = p < 10 ? 30 : p;
        NSInteger hh = [cfg[@"heal_interval"] integerValue];
        self.baseHealSec = hh < 30 ? 120 : hh;
    } else if (self.basePollSec == 0) {
        self.basePollSec = 30;   // defensive: never reloaded yet
        self.baseHealSec = 120;
    }

    double mult = [self cadenceMultiplier];
    if (!reloadBase && self.pollTimer != nil && mult == self.appliedCadenceMult) {
        return; // no change — avoid timer churn
    }
    self.appliedCadenceMult = mult;

    [self.pollTimer invalidate];
    [self.healTimer invalidate];

    NSTimeInterval pollIv = self.basePollSec * mult;
    NSTimeInterval healIv = self.baseHealSec * mult;

    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:pollIv
        target:self selector:@selector(pollStatus:) userInfo:nil repeats:YES];
    self.pollTimer.tolerance = pollIv * 0.25;

    self.healTimer = [NSTimer scheduledTimerWithTimeInterval:healIv
        target:self selector:@selector(autoHealCheck:) userInfo:nil repeats:YES];
    self.healTimer.tolerance = healIv * 0.25;
}

- (void)pollStatus:(NSTimer *)timer {
    [self refreshStatusFast];     // native getmntinfo — no subprocess/network (energy #2)
    [self drainEndpointEvents];
    [self buildMenu];
    [self applyTimerCadence:NO];  // adapt cadence to fresh state (energy #3/#5)
    // VPN status is refreshed event-driven (launch / menu-open / network change
    // / wake), not per-poll — drops a `discover.sh detect-vpn` subprocess every
    // tick. VPN topology only changes on those events.
}

@end

// Network change C callback
void networkChangeCallback(CFNotificationCenterRef center, void *observer,
    CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    AppDelegate *del = (__bridge AppDelegate *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [del networkChanged:nil];
    });
}

// ─── Main ───────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        AppDelegate *del = [AppDelegate new];
        app.delegate = del;
        [app run];
    }
    return 0;
}
