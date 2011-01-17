// Copyright (c) 2010-2011, Rasmus Andersson. All rights reserved.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

#import <Cocoa/Cocoa.h>

@class SUUpdater, KTerminalUsageWindowController;

@interface KAppDelegate : NSObject <NSApplicationDelegate> {
  IBOutlet SUUpdater *sparkleUpdater_;
  IBOutlet NSMenu *syntaxModeMenu_;
  IBOutlet NSMenuItem *show80charsMenuItem_;
  IBOutlet NSMenuItem *coverBackgroundMenuItem_;
  KTerminalUsageWindowController *terminalUsageWindowController_;
  NSWindow *backgroundCoverWindow_;
}

- (IBAction)newWindow:(id)sender;
- (IBAction)newDocument:(id)sender;  // "New tab"
- (IBAction)displayTerminalUsage:(id)sender;
- (IBAction)displayAbout:(id)sender;
- (IBAction)showColumnGuide:(id)sender;
- (IBAction)coverBackground:(id)sender;

- (void)_createBackgroundCoverWindow;

@end
