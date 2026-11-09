// 精简 umbrella：按官方 Sparkle.h 顺序 + 递归依赖补齐
#ifndef SPARKLE_H
#define SPARKLE_H
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Sparkle/SUExport.h>
#import <Sparkle/SUAppcast.h>
#import <Sparkle/SUAppcastItem.h>
#import <Sparkle/SUStandardVersionComparator.h>
#import <Sparkle/SPUUpdater.h>
#import <Sparkle/SPUUpdaterDelegate.h>
#import <Sparkle/SPUUpdaterSettings.h>
#import <Sparkle/SUVersionComparisonProtocol.h>
#import <Sparkle/SUVersionDisplayProtocol.h>
#import <Sparkle/SUErrors.h>
#import <Sparkle/SPUUpdatePermissionRequest.h>
#import <Sparkle/SUUpdatePermissionResponse.h>
#import <Sparkle/SPUUserDriver.h>
#import <Sparkle/SPUDownloadData.h>
#import <Sparkle/SPUStandardUpdaterController.h>
#import <Sparkle/SPUStandardUserDriver.h>
#import <Sparkle/SPUStandardUserDriverDelegate.h>
#import <Sparkle/SUUpdater.h>
#import <Sparkle/SUUpdaterDelegate.h>
#import <Sparkle/SPUAppcastSigningValidationStatus.h>
#import <Sparkle/SPUUpdateCheck.h>
#import <Sparkle/SPUUserUpdateState.h>
#endif
