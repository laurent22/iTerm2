//
//  TmuxController.m
//  iTerm
//
//  Created by George Nachman on 11/27/11.
//

#import "TmuxController.h"
#import "TmuxGateway.h"
#import "TSVParser.h"
#import "PseudoTerminal.h"
#import "iTermController.h"
#import "TmuxWindowOpener.h"
#import "PTYTab.h"
#import "PseudoTerminal.h"
#import "PTYTab.h"
#import "RegexKitLite.h"

@interface TmuxController (Private)

- (void)retainWindow:(int)window withTab:(PTYTab *)tab;
- (void)releaseWindow:(int)window;

@end

@implementation TmuxController

@synthesize gateway = gateway_;

- (id)initWithGateway:(TmuxGateway *)gateway
{
    self = [super init];
    if (self) {
        gateway_ = [gateway retain];
        windowPanes_ = [[NSMutableDictionary alloc] init];
        windows_ = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [gateway_ release];
    [windowPanes_ release];
    [windows_ release];
    [super dealloc];
}

- (void)openWindowWithIndex:(int)windowIndex
                       name:(NSString *)name
                       size:(NSSize)size
                     layout:(NSString *)layout
{
    TmuxWindowOpener *windowOpener = [TmuxWindowOpener windowOpener];
    windowOpener.windowIndex = windowIndex;
    windowOpener.name = name;
    windowOpener.size = size;
    windowOpener.layout = layout;
    windowOpener.maxHistory = 1000;
    windowOpener.controller = self;
    windowOpener.gateway = gateway_;
    [windowOpener openWindows:YES];
}

- (void)setLayoutInTab:(PTYTab *)tab
                toLayout:(NSString *)layout
{
    TmuxWindowOpener *windowOpener = [TmuxWindowOpener windowOpener];
    windowOpener.layout = layout;
    windowOpener.controller = self;
    windowOpener.gateway = gateway_;
    windowOpener.windowIndex = [tab tmuxWindow];
    [windowOpener updateLayoutInTab:tab];
}

- (void)initialListWindowsResponse:(NSString *)response
{
    TSVDocument *doc = [response tsvDocument];
    if (!doc) {
        [gateway_ abortWithErrorMessage:[NSString stringWithFormat:@"Bad response for initial list windows request: %@", response]];
        return;
    }
    for (NSArray *record in doc.records) {
        [self openWindowWithIndex:[[doc valueInRecord:record forField:@"window_id"] intValue]
                             name:[doc valueInRecord:record forField:@"window_name"]
                             size:NSMakeSize([[doc valueInRecord:record forField:@"window_width"] intValue],
                                             [[doc valueInRecord:record forField:@"window_height"] intValue])
                           layout:[doc valueInRecord:record forField:@"window_layout"]];
    }
}

- (void)openWindowsInitial
{
    [gateway_ sendCommand:@"list-windows -C"
           responseTarget:self
         responseSelector:@selector(initialListWindowsResponse:)];
}

- (NSNumber *)_keyForWindowPane:(int)windowPane
{
    return [NSNumber numberWithInt:windowPane];
}

- (PTYSession *)sessionForWindowPane:(int)windowPane
{
    return [windowPanes_ objectForKey:[self _keyForWindowPane:windowPane]];
}

- (void)registerSession:(PTYSession *)aSession
               withPane:(int)windowPane
               inWindow:(int)window
{
    [self retainWindow:window withTab:[aSession tab]];
    [windowPanes_ setObject:aSession forKey:[self _keyForWindowPane:windowPane]];
}

- (void)deregisterWindow:(int)window windowPane:(int)windowPane
{
    [self releaseWindow:window];
    [windowPanes_ removeObjectForKey:[self _keyForWindowPane:windowPane]];
}

- (PTYTab *)window:(int)window
{
    return [[windows_ objectForKey:[NSNumber numberWithInt:window]] objectAtIndex:0];
}

- (void)detach
{
    // Close all sessions. Iterate over a copy of windowPanes_ because the loop
    // body modifies it by closing sessions.
    for (NSString *key in [[windowPanes_ copy] autorelease]) {
        PTYSession *session = [windowPanes_ objectForKey:key];
        [[[session tab] realParentWindow] closeSession:session];
    }

    // Clean up all state to avoid trying to reuse it.
    [windowPanes_ removeAllObjects];
    [gateway_ release];
    gateway_ = nil;
}

- (void)windowDidResize:(PseudoTerminal *)term
{
    NSSize size = [term tmuxCompatibleSize];
    ++numOutstandingWindowResizes_;
    [gateway_ sendCommand:[NSString stringWithFormat:@"set-control-client-attr client-size %d,%d", (int) size.width, (int)size.height]
           responseTarget:self
         responseSelector:@selector(clientSizeChangeResponse:)
           responseObject:nil];
}

- (BOOL)hasOutstandingWindowResize
{
    return numOutstandingWindowResizes_ > 0;
}

- (void)windowPane:(int)wp
         resizedBy:(int)amount
      horizontally:(BOOL)wasHorizontal
{
    NSString *dir;
    if (wasHorizontal) {
        if (amount > 0) {
            dir = @"R";
        } else {
            dir = @"L";
        }
    } else {
        if (amount > 0) {
            dir = @"D";
        } else {
            dir = @"U";
        }
    }
    NSString *cmdStr = [NSString stringWithFormat:@"resize-pane -%@ -t %%%d %d",
                        dir, wp, abs(amount)];
    ++numOutstandingWindowResizes_;
    [gateway_ sendCommand:cmdStr
           responseTarget:self
         responseSelector:@selector(clientSizeChangeResponse:)
           responseObject:nil];
}

// The splitVertically parameter uses the iTerm2 conventions.
- (void)splitWindowPane:(int)wp vertically:(BOOL)splitVertically
{
    // No need for a callback. We should get a layout-changed message and act on it.
    [gateway_ sendCommand:[NSString stringWithFormat:@"split-window -%@ -t %%%d", splitVertically ? @"h": @"v", wp]
           responseTarget:nil
         responseSelector:nil];
}

@end

@implementation TmuxController (Private)

// When an iTerm2 window is resized, a set-control-client-attr client-size w,h
// command is sent. It responds with new layouts for all the windows in the
// client's session. Update the layouts for the affected tabs.
- (void)clientSizeChangeResponse:(NSString *)response
{
    --numOutstandingWindowResizes_;
    NSArray *layoutStrings = [response componentsSeparatedByString:@"\n"];
    for (NSString *layoutString in layoutStrings) {
        NSArray *components = [layoutString captureComponentsMatchedByRegex:@"^([0-9]+) (.*)"];
        if ([components count] != 3) {
            NSLog(@"Bogus layout string: \"%@\"", layoutString);
        } else {
            int window = [[components objectAtIndex:1] intValue];
            NSString *layout = [components objectAtIndex:2];
            PTYTab *tab = [self window:window];
            if (tab) {
                [[gateway_ delegate] tmuxUpdateLayoutForWindow:window
                                                        layout:layout];
            }
        }
    }
}

- (void)retainWindow:(int)window withTab:(PTYTab *)tab
{
    NSNumber *k = [NSNumber numberWithInt:window];
    NSMutableArray *entry = [windows_ objectForKey:k];
    if (entry) {
        NSNumber *refcount = [entry objectAtIndex:1];
        [entry replaceObjectAtIndex:1 withObject:[NSNumber numberWithInt:[refcount intValue] + 1]];
    } else {
        entry = [NSMutableArray arrayWithObjects:tab, [NSNumber numberWithInt:1], nil];
    }
    [windows_ setObject:entry forKey:k];
}

- (void)releaseWindow:(int)window
{
    NSNumber *k = [NSNumber numberWithInt:window];
    NSMutableArray *entry = [windows_ objectForKey:k];
    NSNumber *refcount = [entry objectAtIndex:1];
    refcount = [NSNumber numberWithInt:[refcount intValue] + 1];
    if ([refcount intValue]) {
        [entry replaceObjectAtIndex:1 withObject:refcount];
        [windows_ setObject:entry forKey:k];
    } else {
        [windows_ removeObjectForKey:k];
        return;
    }
}

@end