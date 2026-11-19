#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>
#import <unistd.h>

// The host owns stdin. EOF ends the helper when the app quits, including during installation.
int main(void) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSURL *hostURL = NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent
            .URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
        NSBundle *host = [NSBundle bundleWithURL:hostURL];
        if (host.bundleIdentifier == nil ||
            ![[host.bundleIdentifier stringByAppendingString:@".updater"]
                isEqualToString:NSBundle.mainBundle.bundleIdentifier]) return 1;

        SPUStandardUserDriver *driver = [[SPUStandardUserDriver alloc] initWithHostBundle:host delegate:nil];
        SPUUpdater *updater = [[SPUUpdater alloc] initWithHostBundle:host applicationBundle:host
                                                         userDriver:driver delegate:nil];
        NSError *error = nil;
        if (![updater startUpdater:&error]) {
            NSLog(@"Cannot start software updates: %@", error.localizedDescription);
            return 1;
        }
        dispatch_source_t commands = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0,
                                                            dispatch_get_main_queue());
        dispatch_source_set_event_handler(commands, ^{
            char bytes[32];
            ssize_t count = read(STDIN_FILENO, bytes, sizeof(bytes));
            if (count < 0 && errno == EINTR) return;
            if (count <= 0) {
                [application terminate:nil];
                return;
            }
            for (ssize_t index = 0; index < count; index++) {
                switch (bytes[index]) {
                    case 'C':
                        if (updater.canCheckForUpdates) {
                            [application activateIgnoringOtherApps:YES];
                            [updater checkForUpdates];
                        }
                        break;
                    case 'Y': updater.automaticallyChecksForUpdates = YES; break;
                    case 'N': updater.automaticallyChecksForUpdates = NO; break;
                }
            }
        });
        dispatch_resume(commands);
        [application run];
        dispatch_source_cancel(commands);
    }
    return 0;
}
