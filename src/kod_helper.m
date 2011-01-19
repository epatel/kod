// Copyright (c) 2010-2011, Rasmus Andersson. All rights reserved.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

#import <getopt.h>
#import <err.h>

#import "kod_version.h"
#import "kod_helper.h"
#import "KMachServiceProtocol.h"
#import "common.h"


@implementation KCLIProgram

@synthesize kodApp = kodApp_,
            kodService = kodService_;


- (id)init {
  if (!(self = [super init])) return nil;

  asyncWaitQueue_ = [NSMutableDictionary new];

  return self;
}


- (void)dealloc {
  [asyncWaitQueue_ release];
  [super dealloc];
}


- (void)printUsageAndExit:(int)exitStatus {
  NSString *msg = [NSString stringWithFormat:
      @"usage: %@ [options] [<file-or-url> ..]\n"
       "options:\n"
       "  -n --nowait-open  Don't wait for Kod.app to open all documents.\n"
       "  -w --wait         Wait until all opened document has been closed.\n"
       "  --kod-app <path>  Communicate with Kod.app at <path>.\n"
       "  -h --help         Display this help message and exit.\n"
       "  --version         Display version info and exit.\n",
      [[NSProcessInfo processInfo] processName]];
  fprintf(stderr, "%s\n", [msg UTF8String]);
  if (exitStatus > -1)
    exit(exitStatus);
}


- (void)parseOptionsOfLength:(int)argc argv:(char**)argv {
  /*
  struct option {
    // name of long option
    const char *name;
    // one of no_argument, required_argument, and optional_argument:
    // whether option takes an argument
    int has_arg;
    // if not NULL, set *flag to val when option found
    int *flag;
    // if flag not NULL, value to set *flag to; else return value
    int val;
  };
  */
  struct option long_options[] = {
    {"nowait-open", no_argument, &optNoWaitOpen_, 1},
    {"wait", no_argument, &optWaitForDocumentClose, 1},
    {"kod-app", required_argument, 0, 0},
    {"version", no_argument, 0, 0},
    {"help", no_argument, 0, 0},
    {0, 0, 0, 0}
  };
  static const char *short_options = "nhw";
  int c;
  while (1) {
    int option_index = 0;
    c = getopt_long(argc, argv, short_options, long_options, &option_index);
    if (c == -1)
      break;
    switch (c) {
      case 0: {
        const char *optname = long_options[option_index].name;
        if (strcmp(optname, "help") == 0) {
          [self printUsageAndExit:123];
        } else if (strcmp(optname, "version") == 0) {
          fprintf(stderr, "kod version %s\n", K_VERSION_STR);
          exit(0);
        } else if (strcmp(optname, "kod-app") == 0) {
          NSString *path = [NSString stringWithUTF8String:optarg];
          kodAppURL_ = [NSURL fileURLWithPath:path isDirectory:YES];
        }
        break;
      }
      case 'n':
        optNoWaitOpen_ = 1;
        break;
      case 'w':
        optWaitForDocumentClose = 1;
        break;
      case '?':
        [self printUsageAndExit:1];
        break;
      default:
        [self printUsageAndExit:123];
    }
  }

  // remaining arguments are paths or URLs
  if (optind < argc) {
    URLsToOpen_ = [NSMutableArray arrayWithCapacity:argc-optind];
    while (optind < argc) {
      NSString *urlStr = [NSString stringWithUTF8String:argv[optind++]];
      if ([urlStr isEqualToString:@"-"]) {
        forceReadStdin_ = YES;
        continue; // don't add to URLsToOpen_
      } else if ([urlStr rangeOfString:@":"].location == NSNotFound) {
        urlStr = [[[NSURL fileURLWithPath:urlStr] absoluteURL] path];
      }
      [URLsToOpen_ addObject:urlStr];
    }
  }
}


- (BOOL)findKodAppAndStartIfNeeded:(BOOL)asyncLaunch {
  // TODO(rsms): Pass NSError instead of exit()ing in this method
  NSWorkspace *workspace = [NSWorkspace sharedWorkspace];

  // find url for Kod.app
  if (!kodAppURL_) {
    kodAppURL_ =
        [workspace URLForApplicationWithBundleIdentifier:@"se.hunch.kod"];
    if (!kodAppURL_)
      errx(1, "Unable to find Kod.app -- have you installed Kod?");
  }

  // launch kod
  NSWorkspaceLaunchOptions launchOptions = 0;
  if (asyncLaunch)
    launchOptions = NSWorkspaceLaunchAsync;
  NSArray *args = [NSArray arrayWithObject:@"--launched-from-kod-helper"];
  NSDictionary *confDict = [NSDictionary dictionaryWithObjectsAndKeys:
      args, NSWorkspaceLaunchConfigurationArguments,
      nil];
  NSError *error;
  kodApp_ = [workspace launchApplicationAtURL:kodAppURL_
                                      options:launchOptions
                                configuration:confDict
                                        error:&error];
  if (!kodApp_) {
    errx(1, "failed to launch Kod.app (%s)", [[error description] UTF8String]);
  }
  return !!kodApp_;
}


- (BOOL)connectToKod:(NSError**)outError timeout:(NSTimeInterval)timeout {
  NSDistantObject *proxyObject = nil;
  long countdownUSec = lround(timeout * 1000000.0);
  const unsigned long yieldUSec = 20000; // 20ms
  while (1) {
    proxyObject = [NSConnection rootProxyForConnectionWithRegisteredName:
                   @K_SHARED_SERVICE_PORT_NAME host:nil];
    if (proxyObject || countdownUSec <= 0)
      break;
    usleep(yieldUSec);
    countdownUSec -= yieldUSec;
  }
  if (!proxyObject) {
    if (outError) {
      *outError = [NSError kodErrorWithFormat:@"Failed to aquire root proxy"
                   " from mach port connection"];
    }
    return NO;
  }
  [proxyObject setProtocolForProxy:@protocol(KMachServiceProtocol)];
  kodService_ = (id<KMachServiceProtocol>)proxyObject;

  return YES;
}


- (NSInvocation*)invocationForHandler:(SEL)handler {
  NSMethodSignature *msig = [self methodSignatureForSelector:handler];
  NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:msig];
  [invocation setSelector:handler];
  [invocation setTarget:self];
  return invocation;
}


- (id)enqueueAsyncActionWithCallback:(id)callback {
  static unsigned long long nextId = 0;
  if (optNoWaitOpen_) return nil;
  NSNumber *key = [NSNumber numberWithUnsignedLongLong:nextId++];
  id callbackVal = [NSNull null];
  if (callback)
    callbackVal = [[callback copy] autorelease];
  [asyncWaitQueue_ setObject:callbackVal forKey:key];
  return key;
}


- (id)dequeueAsyncAction:(id)key {
  id val = [asyncWaitQueue_ objectForKey:key];
  if (val) {
    [asyncWaitQueue_ removeObjectForKey:key];
    if (val == [NSNull null])
      val = nil;
  }
  return val;
}


- (void)_didCompleteAsyncAction:(id)key error:(NSError*)error
    arg1:(id)arg1 arg2:(id)arg2 arg3:(id)arg3
    arg4:(id)arg4 arg5:(id)arg5 arg6:(id)arg6 {
  id val = [self dequeueAsyncAction:key];
  if (val) {
    ((void(^)(NSError*,id,id,id,id,id,id))(val))(
        error,arg1,arg2,arg3,arg4,arg5,arg6);
  }
}


- (void)cancelAsyncAction:(id)key {
  [self dequeueAsyncAction:key];
}


- (NSInvocation*)registerCallback:(id)callback {
  NSInvocation *invocation = [self invocationForHandler:
      @selector(_didCompleteAsyncAction:error:arg1:arg2:arg3:arg4:arg5:arg6:)];
  id key = [self enqueueAsyncActionWithCallback:callback];
  if (!key) {
    // not registered
    return nil;
  }
  [invocation setArgument:&key atIndex:2];
  return invocation;
}


- (void)openNewDocumentWithStdin {
  fd_set readfs;
  struct timeval tv;
  tv.tv_sec = 1;
  tv.tv_usec = 500000;
  FD_ZERO(&readfs);
  FD_SET(STDIN_FILENO, &readfs);

  int status = select(FD_SETSIZE, &readfs, NULL, NULL, &tv);
  if (status < 0) {
    WLOG("failed to select on stdin");
    return;
  } else if (!FD_ISSET(STDIN_FILENO, &readfs)) {
    DLOG("stdin is closed");
    return;
  }

  // force binary mode
  FILE *f = freopen(NULL, "rb", stdin);
  NSFileHandle *fh =
      [[[NSFileHandle alloc] initWithFileDescriptor:fileno(f)] autorelease];

  // create close callback if needed
  NSInvocation *closeCallback = nil;
  if (optWaitForDocumentClose) {
    closeCallback = [self registerCallback:^(NSURL *url) {
      DLOG("close callback for stdin executed with final url %@", url);
      printf("-\t%s\n", url ? [[url description] UTF8String] : "");
    }];
  }

  DLOG("reading stdin [%d] until EOF...", [fh fileDescriptor]);
  NSData *data = [fh readDataToEndOfFile];
  [kodService_ openNewDocumentWithData:data
                                ofType:nil
                          openCallback:[self registerCallback:^(NSError *err) {
    DLOG("openNewDocumentWithData callback executed. err: %@", err);
  }]
                         closeCallback:closeCallback];
}


- (void)openAnyURLs {
  if (!URLsToOpen_ || URLsToOpen_.count == 0) return;
  DLOG("invoking openURLs:");
  NSInvocation *errorCallback = [self registerCallback:^(NSError *err) {
    DLOG("openAnyURLs callback executed. err: %@", err);
  }];

  // create close callbacks if needed
  NSMutableArray *closeCallbacks = nil;
  if (optWaitForDocumentClose) {
    closeCallbacks = [NSMutableArray arrayWithCapacity:URLsToOpen_.count];
    NSUInteger i, count = URLsToOpen_.count;
    for (i = 0; i < count; ++i) {
      NSURL *requestedURL = [URLsToOpen_ objectAtIndex:i];
      [closeCallbacks addObject:[self registerCallback:^(NSURL *url){
        DLOG("close callback executed with final url: %@", url);
        NSString *urlstr =
            url ? ([url isFileURL] ? [url path] : [url description]) : nil;
        printf("%s\t%s\n", [[requestedURL description] UTF8String],
               urlstr ? [urlstr UTF8String] : "");
      }]];
    }
  }

  [kodService_ openURLs:URLsToOpen_
           openCallback:errorCallback
         closeCallbacks:closeCallbacks];
}


- (void)takeAppropriateAction {
  // If we where passed any URLs, open them
  [self openAnyURLs];

  // Check if we are receiving input from a terminal
  BOOL inputIsTTY = isatty(STDIN_FILENO);

  // If stdin isn't a TTY, we are probably being piped
  if (!inputIsTTY || forceReadStdin_) {
    [self openNewDocumentWithStdin];
  }

  if (inputIsTTY)
    DLOG("connected to TTY \"%s\"", ttyname(STDIN_FILENO));
}


- (void)waitUntilDone {
  NSRunLoop *rl = [NSRunLoop mainRunLoop];

  while ([asyncWaitQueue_ count] != 0) {
    NSDate *limitDate = [NSDate dateWithTimeIntervalSinceNow:30.0];
    if (![rl runMode:NSDefaultRunLoopMode beforeDate:limitDate]) {
      WLOG("internal runloop error -- bailing out");
      break;
    }
  }
}


@end



int main(int argc, char *argv[]) {
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  KCLIProgram *program = [[KCLIProgram new] autorelease];

  // parse command line arguments
  [program parseOptionsOfLength:argc argv:argv];

  // make sure kod is launched, or launch kod and block until launched
  [program findKodAppAndStartIfNeeded:NO];

  // connect to Kod.app
  NSError *error;
  if (![program connectToKod:&error timeout:30.0]) {
    WLOG("Connection to Kod.app failed: %@", error);
    exit(1);
  }

  DLOG("Connected to Kod.app"
       "\n  Application: %@"
       "\n  Service:     %@",
       program.kodApp,
       program.kodService);

  // take any appropriate action based on parsed arguments and other state
  @try {
    [program takeAppropriateAction];

    // block until done (this causes the runloop to run if needed)
    [program waitUntilDone];
  } @catch (NSException *e) {
    WLOG("%@: %@\n  %@", [e name], [e reason],
         [[e callStackSymbols] componentsJoinedByString:@"\n  "]);
  }

  [pool drain];
  _exit(0);
}
