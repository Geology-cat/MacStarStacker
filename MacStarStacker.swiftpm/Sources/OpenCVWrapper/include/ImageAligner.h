#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h> // Since this is a Mac app

NS_ASSUME_NONNULL_BEGIN

@interface ImageAligner : NSObject

/// Align the given raw image URL against the base image URL and return the aligned image
+ (NSImage * _Nullable)alignImageAtURL:(NSURL *)targetURL
                        toBaseImageAtURL:(NSURL *)baseURL
                                   error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
