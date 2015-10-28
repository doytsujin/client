//
//  KBHelperTool.m
//  Keybase
//
//  Created by Gabriel on 5/10/15.
//  Copyright (c) 2015 Gabriel Handford. All rights reserved.
//

#import "KBHelperTool.h"

#import "KBDebugPropertiesView.h"
#import "KBPrivilegedTask.h"

#import <ObjectiveSugar/ObjectiveSugar.h>
#import <ServiceManagement/ServiceManagement.h>
#import <MPMessagePack/MPXPCClient.h>

#import "KBSemVersion.h"
#import "KBFormatter.h"

#define PLIST_DEST (@"/Library/LaunchDaemons/keybase.Helper.plist")
#define HELPER_LOCATION (@"/Library/PrivilegedHelperTools/keybase.Helper")

@interface KBHelperTool ()
@property KBDebugPropertiesView *infoView;
@property KBSemVersion *version;
@end

@implementation KBHelperTool

- (NSString *)name {
  return @"Privileged Helper";
}

- (NSString *)info {
  return @"Runs privileged tasks";
}

- (NSImage *)image {
  return [KBIcons imageForIcon:KBIconExtension];
}

- (NSView *)componentView {
  [self componentDidUpdate];
  return _infoView;
}

- (KBSemVersion *)bundleVersion {
  return [KBSemVersion version:NSBundle.mainBundle.infoDictionary[@"KBHelperVersion"] build:NSBundle.mainBundle.infoDictionary[@"KBHelperBuild"]];
}

- (void)componentDidUpdate {


  GHODictionary *info = [GHODictionary dictionary];
  info[@"Version"] = GHOrNull(_version);
  info[@"Bundle Version"] = [[self bundleVersion] description];

  GHODictionary *statusInfo = [self componentStatusInfo];
  if (statusInfo) [info addEntriesFromOrderedDictionary:statusInfo];

  info[@"Plist"] = PLIST_DEST;

  if (!_infoView) _infoView = [[KBDebugPropertiesView alloc] init];
  [_infoView setProperties:info];
}

- (void)refreshComponent:(KBCompletion)completion {
  _version = nil;
  if (![NSFileManager.defaultManager fileExistsAtPath:PLIST_DEST isDirectory:nil] &&
      ![NSFileManager.defaultManager fileExistsAtPath:HELPER_LOCATION isDirectory:nil]) {
    self.componentStatus = [KBComponentStatus componentStatusWithInstallStatus:KBRInstallStatusNotInstalled runtimeStatus:KBRuntimeStatusNone info:nil];
    completion(nil);
    return;
  }

  KBSemVersion *bundleVersion = [self bundleVersion];
  GHODictionary *info = [GHODictionary dictionary];
  GHWeakSelf gself = self;
  MPXPCClient *helper = [[MPXPCClient alloc] initWithServiceName:@"keybase.Helper" privileged:YES readOptions:MPMessagePackReaderOptionsUseOrderedDictionary];
  [helper sendRequest:@"version" params:nil completion:^(NSError *error, NSDictionary *versions) {
    if (error) {
      self.componentStatus = [KBComponentStatus componentStatusWithInstallStatus:KBRInstallStatusInstalled runtimeStatus:KBRuntimeStatusNotRunning info:nil];
      completion(error);
    } else {
      KBSemVersion *runningVersion = [KBSemVersion version:KBIfNull(versions[@"version"], @"") build:KBIfNull(versions[@"build"], nil)];
      gself.version = runningVersion;
      if (runningVersion) info[@"Version"] = [runningVersion description];
      if ([bundleVersion isGreaterThan:runningVersion]) {
        if (bundleVersion) info[@"New version"] = [bundleVersion description];
        self.componentStatus = [KBComponentStatus componentStatusWithInstallStatus:KBRInstallStatusNeedsUpgrade runtimeStatus:KBRuntimeStatusRunning info:info];
        completion(nil);
      } else {
        self.componentStatus = [KBComponentStatus componentStatusWithInstallStatus:KBRInstallStatusInstalled runtimeStatus:KBRuntimeStatusRunning info:info];
        completion(nil);
      }
    }
  }];
}

- (void)install:(KBCompletion)completion {
  NSError *error = nil;
  if ([self installPrivilegedServiceWithName:@"keybase.Helper" error:&error]) {
    completion(nil);
  } else {
    if (!error) error = KBMakeError(KBErrorCodeInstallError, @"Failed to install privileged helper");
    completion(error);
  }
}

- (BOOL)installPrivilegedServiceWithName:(NSString *)name error:(NSError **)error {
  AuthorizationRef authRef;
  OSStatus osstatus = AuthorizationCreate(NULL, NULL, 0, &authRef);
  if (osstatus != errAuthorizationSuccess) {
    if (error) *error = KBMakeError(osstatus, @"Error creating auth");
    return NO;
  }

  AuthorizationItem authItem = {kSMRightBlessPrivilegedHelper, 0, NULL, 0};
  AuthorizationRights authRights = {1, &authItem};
  AuthorizationFlags flags =	kAuthorizationFlagDefaults | kAuthorizationFlagInteractionAllowed	| kAuthorizationFlagPreAuthorize | kAuthorizationFlagExtendRights;
  osstatus = AuthorizationCopyRights(authRef, &authRights, kAuthorizationEmptyEnvironment, flags, NULL);
  if (osstatus != errAuthorizationSuccess) {
    if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:osstatus userInfo:nil];
    return NO;
  }

  CFErrorRef cerror = NULL;
  Boolean success = SMJobBless(kSMDomainSystemLaunchd, (__bridge CFStringRef)name, authRef, &cerror);
  if (!success) {
    if (error) *error = (NSError *)CFBridgingRelease(cerror);
    return NO;
  } else {
    return YES;
  }
}

- (void)uninstall:(KBCompletion)completion {
  NSString *path = NSStringWithFormat(@"%@/bin/uninstall_helper", NSBundle.mainBundle.sharedSupportPath);

  NSError *error = nil;
  KBPrivilegedTask *task = [[KBPrivilegedTask alloc] init];
  [task execute:@"/bin/sh" args:@[path] error:&error];
  if (error) {
    completion(error);
    return;
  }
  completion(nil);

  /*
  NSArray *commands = @[
                        @{@"cmd": @"/bin/rm", @"args": @[@"/Library/PrivilegedHelperTools/keybase.Helper"]},
                        @{@"cmd": @"/bin/launchctl", @"args": @[@"unload", @"/Library/LaunchDaemons/keybase.Helper.plist"]},
                        @{@"cmd": @"/bin/rm", @"args": @[@"/Library/LaunchDaemons/keybase.Helper.plist"]},];

  NSError *error = nil;
  KBPrivilegedTask *task = [[KBPrivilegedTask alloc] init];
  for (NSArray *command in commands) {
    [task execute:command[@"cmd"] args:command[@"args"] error:&error];
    if (error) {
      completion(error);
      return;
    }
  }
  completion(nil);
   */
}

- (void)start:(KBCompletion)completion {
  completion(KBMakeError(KBErrorCodeUnsupported, @"Unsupported"));
}

- (void)stop:(KBCompletion)completion {
  completion(KBMakeError(KBErrorCodeUnsupported, @"Unsupported"));
}

@end
