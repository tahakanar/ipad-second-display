#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns the lifetime of a single WindowServer display. Releasing the object removes the display.
@interface VirtualDesktop : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
+ (nullable instancetype)createWithWidth:(NSUInteger)width
                                  height:(NSUInteger)height
                            serialNumber:(uint32_t)serialNumber
                                   error:(NSError **)error NS_SWIFT_NAME(create(width:height:serialNumber:));
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
