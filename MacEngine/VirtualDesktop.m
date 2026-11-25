#import "VirtualDesktop.h"

// These CoreGraphics classes are undocumented. Resolve them at runtime so an
// incompatible macOS release produces an actionable startup error.
@protocol DesktopDescriptor <NSObject>
@property(nonatomic, copy) NSString *name;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic) unsigned int vendorID, productID, serialNum, serialNumber;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@end
@protocol DesktopSurface <NSObject>
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@end
@protocol DesktopMode <NSObject>
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@protocol DesktopSettings <NSObject>
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic, copy) NSArray *modes;
@end

@implementation VirtualDesktop {
    id<DesktopSurface> _surface;
}
- (instancetype)initWithSurface:(id<DesktopSurface>)surface {
    self = [super init];
    if (self) _surface = surface;
    return self;
}
- (CGDirectDisplayID)displayID {
    return _surface.displayID;
}

static VirtualDesktop *Failure(NSError **error, NSString *reason) {
    if (error) {
        *error = [NSError errorWithDomain:@"MacDisplay.VirtualDesktop" code:1
                                 userInfo:@{NSLocalizedDescriptionKey: reason}];
    }
    return nil;
}

+ (instancetype)createWithWidth:(NSUInteger)width height:(NSUInteger)height
                   serialNumber:(uint32_t)serialNumber error:(NSError **)error {
    Class descriptorType = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class surfaceType = NSClassFromString(@"CGVirtualDisplay");
    Class modeType = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsType = NSClassFromString(@"CGVirtualDisplaySettings");
    if (!descriptorType || !surfaceType || !modeType || !settingsType)
        return Failure(error, @"Bu macOS sürümünde sanal ekran bileşenleri bulunamadı.");

    @try {
        id<DesktopDescriptor> descriptor = [[descriptorType alloc] init];
        descriptor.name = @"iPad Ekranı";
        descriptor.queue = dispatch_get_main_queue();
        descriptor.vendorID = 0x4950;
        descriptor.productID = 0x5344;
        descriptor.serialNum = serialNumber;
        if ([descriptor respondsToSelector:@selector(setSerialNumber:)]) descriptor.serialNumber = serialNumber;
        descriptor.maxPixelsWide = (unsigned int)width;
        descriptor.maxPixelsHigh = (unsigned int)height;
        descriptor.sizeInMillimeters = CGSizeMake(width * 25.4 / 264., height * 25.4 / 264.);
        descriptor.redPrimary = CGPointMake(0.640, 0.330);
        descriptor.greenPrimary = CGPointMake(0.300, 0.600);
        descriptor.bluePrimary = CGPointMake(0.150, 0.060);
        descriptor.whitePoint = CGPointMake(0.3127, 0.3290);

        id<DesktopSurface> display = [(id<DesktopSurface>)[surfaceType alloc] initWithDescriptor:descriptor];
        id<DesktopMode> mode = [(id<DesktopMode>)[modeType alloc] initWithWidth:(unsigned int)width / 2
                                                                        height:(unsigned int)height / 2
                                                                   refreshRate:60.0];
        if (!display || !mode) return Failure(error, @"macOS sanal ekranı oluşturamadı.");
        id<DesktopSettings> settings = [[settingsType alloc] init];
        settings.hiDPI = 1;
        settings.modes = @[mode];
        if (![display applySettings:settings] || display.displayID == kCGNullDirectDisplay)
            return Failure(error, @"macOS Retina ekran modunu etkinleştiremedi.");
        return [[VirtualDesktop alloc] initWithSurface:display];
    } @catch (NSException *exception) {
        return Failure(error, @"Sanal ekran arabirimi bu macOS sürümüyle uyumlu değil.");
    }
}
@end
