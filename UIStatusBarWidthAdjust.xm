//  Oh My Insets - iOS 17 / roothide compatibility build
//  ------------------------------------------------------------------
//  原版 1.2 官方只声明支持 iOS 15/16。它在 %ctor 里无条件对 ~20 个私有类调用
//  MSHookMessageEx，且：
//    1) 类不存在时 objc_getClass 返回 Nil，hook 静默丢失 -> 功能失效；
//    2) 类存在但方法不存在时 Substrate 会「新增」该方法，%orig 指针为
//       NULL，Logos 生成的尾调用 braaz NULL => EXC_BAD_ACCESS / 安全模式；
//    3) MSHookIvar 在 ivar 不存在时得到 NULL 引用，随后 str 写入 0x0；
//    4) 全局 hook UIView 私有方法 _setContinuousCornerRadius: 风险最高。
//  iOS 17 上这些私有类/ivar 有变动，因此一 respring 就进安全模式。
//
//  本版本：
//    - 每个 hook 组按「类 + 实例方法」逐项校验，缺失则整组跳过（不注册）；
//    - 组按需延迟初始化（NSBundleDidLoadNotification + 延时重试 + 设置热重载），
//      框架晚加载也能装上 hook，功能不丢；
//    - 所有 ivar 读写、私有方法调用都做存在性 / KVC 兜底，绝不写 0x0；
//    - 保持原有全部设置项与功能：状态栏左右内边距、控制中心五列及配套外观。
//    - 诊断结果写入 com.82flex.ohmyinsets 域的 omiStatus / omiMissing，
//      可在设置面板「兼容性诊断」里直接看到。
//  ------------------------------------------------------------------

#import <notify.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <HBLog.h>

#import "UISBWAPrefs/UISBWAUserDefaults.h"

#pragma mark - Settings

static BOOL _gIsEnabled = NO;
static BOOL _gIsFiveColumnsEnabled = NO;

static CGFloat _gCompactLeadingInset = 0.0;
static CGFloat _gCompactTrailingInset = 0.0;
static CGFloat _gExpandedLeadingInset = 0.0;
static CGFloat _gExpandedTrailingInset = 0.0;

static CGFloat _gCCUIGlobalFontSize = 13.0;
static CGFloat _gCCUIGlobalIconScale = 0.8;
static CGFloat _gCCUIGlobalCornerRadius = 12.0;

static void ReloadPrefs(void) {
    _gIsEnabled = waBool(@"isEnabled");
    _gIsFiveColumnsEnabled = waBool(@"isFiveColumnsEnabled");
    _gCompactLeadingInset = waDouble(@"compactLeadingInset");
    _gCompactTrailingInset = waDouble(@"compactTrailingInset");
    _gExpandedLeadingInset = waDouble(@"expandedLeadingInset");
    _gExpandedTrailingInset = waDouble(@"expandedTrailingInset");
}

#pragma mark - Layout structs (unchanged ABI)

typedef struct {
  unsigned long long width;
  unsigned long long height;
} CCUILayoutPoint;

typedef struct {
  unsigned long long width;
  unsigned long long height;
} CCUILayoutSize;

typedef struct {
    CCUILayoutPoint origin;
    CCUILayoutSize size;
} CCUILayoutRect;

#pragma mark - Private class declarations (compile-time only)

@interface CCUIControlCenterPositionProviderPackingRule : NSObject
@property(nonatomic, readonly) unsigned long long packFrom;
@property(nonatomic, readonly) unsigned long long packingOrder;
@property(nonatomic, readonly) CCUILayoutSize sizeLimit;
@end

@interface CCUIStatusBar : UIView
@property(assign, nonatomic) long long orientation;
@end

@interface CCUIMutableLayoutOptions : NSObject
@property(assign, nonatomic) CGFloat itemEdgeSize;
@property(assign, nonatomic) CGFloat itemSpacing;
- (void)recalculateItemLayouts;
@end

@interface CCUIButtonModuleView : UIView
@end

@interface CCUIBaseSliderView : UIView
@end

@interface CCUILabeledRoundButton : UIView
@end

@interface CCUIConnectivityModuleViewController : UIViewController
@property(getter=isExpanded, nonatomic, readonly) BOOL expanded;
@end

@interface FCCCModuleViewController : UIViewController
@end

@interface MRUTransportButton : UIView
@end

@interface MRUMarqueeLabel : UILabel
@end

@interface MRUNowPlayingLabelView : UIView
@property(assign, nonatomic) long long layout;
@property(nonatomic, strong) UILabel *placeholderLabel;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *subtitleLabel;
@property(nonatomic, strong) MRUMarqueeLabel *placeholderMarqueeView;
@property(nonatomic, strong) MRUMarqueeLabel *titleMarqueeView;
@property(nonatomic, strong) MRUMarqueeLabel *subtitleMarqueeView;
@end

@interface MRUNowPlayingHeaderView : UIView
@property(nonatomic, strong) MRUNowPlayingLabelView *labelView;
@end

@interface MRUNowPlayingRoutingButton : UIView
@end

@interface CCUIContentModuleContainerViewController : UIViewController
@end

@interface CCUIContinuousSliderView : UIView
@end

@interface CCUIControlCenterPositionProvider : NSObject
@end

@interface HACCIconViewController : UIViewController
@end

@interface UIView (OMIPrivate)
- (void)_setContinuousCornerRadius:(CGFloat)arg1;
@end

#pragma mark - Forward declarations

static void OMITryInitGroups(void);
static void OMIUpdateStatus(void);

#pragma mark - Diagnostics / safety helpers

#define OMILog(fmt, ...) HBLogWarn((@"[OMI17] " fmt), ##__VA_ARGS__)

static NSUserDefaults *OMIDefaults(void) {
    return [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.ohmyinsets"];
}

static void OMISetDiagnostic(NSString *key, NSString *value) {
    if (!value) value = @"(nil)";
    [OMIDefaults() setObject:value forKey:key];
    OMILog(@"%@ = %@", key, value);
}

static NSMutableString *gMissing = nil;

static void OMINoteMissing(NSString *what) {
    if (!gMissing) gMissing = [NSMutableString new];
    if ([gMissing length] < 600 && [gMissing rangeOfString:what].location == NSNotFound) {
        [gMissing appendFormat:@"%@ ", what];
        [OMIDefaults() setObject:gMissing forKey:@"omiMissing"];
    }
}

typedef struct {
    const char *cls;
    const char *sel;
} OMIRequirement;

// 关键：只有「类存在 且 实例方法存在」才允许注册 hook，
// 否则 %orig 会是 NULL，调用即崩溃。
static BOOL OMIRequirementsMet(const OMIRequirement *reqs, size_t count) {
    for (size_t i = 0; i < count; i++) {
        Class cls = objc_getClass(reqs[i].cls);
        SEL sel = sel_registerName(reqs[i].sel);
        if (!cls || !class_getInstanceMethod(cls, sel)) {
            OMINoteMissing([NSString stringWithFormat:@"%s.%s", reqs[i].cls, reqs[i].sel]);
            return NO;
        }
    }
    return YES;
}

// 结构体按值传参的方法：确认第 3 个参数仍是 struct，避免 iOS 改签名后 ABI 不一致
static BOOL OMIArg2IsStruct(const char *clsName, const char *selName) {
    Class cls = objc_getClass(clsName);
    Method m = cls ? class_getInstanceMethod(cls, sel_registerName(selName)) : NULL;
    if (!m || method_getNumberOfArguments(m) < 3) return NO;
    char *arg = method_copyArgumentType(m, 2);
    BOOL ok = (arg && arg[0] == '{');
    free(arg);
    return ok;
}

static BOOL OMIIsKindOf(id obj, const char *clsName) {
    Class cls = objc_getClass(clsName);
    return (obj && cls) ? [obj isKindOfClass:cls] : NO;
}

#pragma mark - ivar access (never dereference NULL)

static Ivar OMIFindIvar(id obj, NSString *name) {
    if (!obj || !name) return NULL;
    return class_getInstanceVariable(object_getClass(obj), name.UTF8String);
}

// 旧名 / 新名都试，最后走 KVC；任何一步失败都安静跳过，绝不写 0x0
static BOOL OMISetDoubleIvar2(id obj, NSString *nameA, NSString *nameB, double value) {
    for (NSString *n in @[nameA, nameB]) {
        Ivar iv = OMIFindIvar(obj, n);
        if (iv) {
            *(double *)((uint8_t *)(__bridge void *)obj + ivar_getOffset(iv)) = value;
            return YES;
        }
    }
    for (NSString *n in @[nameA, nameB]) {
        @try {
            [obj setValue:@(value) forKey:n];
            return YES;
        } @catch (__unused NSException *e) {}
    }
    OMINoteMissing([NSString stringWithFormat:@"ivar.%@", nameA]);
    return NO;
}

static double OMIGetDoubleIvar2(id obj, NSString *nameA, NSString *nameB, double fallback) {
    for (NSString *n in @[nameA, nameB]) {
        Ivar iv = OMIFindIvar(obj, n);
        if (iv) return *(double *)((uint8_t *)(__bridge void *)obj + ivar_getOffset(iv));
    }
    for (NSString *n in @[nameA, nameB]) {
        @try {
            id v = [obj valueForKey:n];
            if (v) return [v doubleValue];
        } @catch (__unused NSException *e) {}
    }
    return fallback;
}

static UIView *OMIGetViewIvar(id obj, NSString *nameA, NSString *nameB) {
    for (NSString *n in @[nameA, nameB]) {
        Ivar iv = OMIFindIvar(obj, n);
        if (iv) {
            @try { return (UIView *)object_getIvar(obj, iv); }
            @catch (__unused NSException *e) { return nil; }
        }
    }
    for (NSString *n in @[nameA, nameB]) {
        @try {
            id v = [obj valueForKey:n];
            if ([v isKindOfClass:[UIView class]]) return (UIView *)v;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

static BOOL OMISetContinuousCornerRadius(UIView *view, CGFloat radius) {
    if (!view) return NO;
    SEL setter = @selector(_setContinuousCornerRadius:);
    if (![view respondsToSelector:setter]) return NO;
    [view _setContinuousCornerRadius:radius];
    return YES;
}

#pragma mark - Group: SpringBoard (always safe, keeps live prefs reload)

%group SpringBoardGroup

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;

    static int token = 0;
    notify_register_dispatch(WA_NOTIFY_NAME, &token, dispatch_get_main_queue(), ^(int t) {
        ReloadPrefs();
        OMITryInitGroups();
    });

    ReloadPrefs();
    OMITryInitGroups();
}

%end

%end // SpringBoardGroup

#pragma mark - Group: status bar insets (功能 1)

%group StatusBarInsetsGroup

%hook CCUIStatusBar

- (void)setCompactEdgeInsets:(UIEdgeInsets)insets {
    if (!_gIsEnabled) { %orig; return; }

    // iOS 17 上 orientation 可能已移除；缺失时按竖屏处理
    BOOL portrait = YES;
    if ([self respondsToSelector:@selector(orientation)]) {
        portrait = (self.orientation == 1);
    }
    if (!portrait) { %orig; return; }

    UIEdgeInsets newInsets = insets;
    newInsets.left = _gCompactLeadingInset;
    newInsets.right = _gCompactTrailingInset;
    %orig(newInsets);
}

- (void)setExpandedEdgeInsets:(UIEdgeInsets)insets {
    if (!_gIsEnabled) { %orig; return; }

    BOOL portrait = YES;
    if ([self respondsToSelector:@selector(orientation)]) {
        portrait = (self.orientation == 1);
    }
    if (!portrait) { %orig; return; }

    UIEdgeInsets newInsets = insets;
    newInsets.left = _gExpandedLeadingInset;
    newInsets.right = _gExpandedTrailingInset;
    %orig(newInsets);
}

%end

%end // StatusBarInsetsGroup

#pragma mark - Group: five-column sizing (功能 2 核心)

%group FiveColumnSizingGroup

%hook CCUIMutableLayoutOptions

- (void)setItemEdgeSize:(CGFloat)edgeSize {
    %orig;
    [self recalculateItemLayouts];
}

- (void)setItemSpacing:(CGFloat)itemSpacing {
    %orig;
    [self recalculateItemLayouts];
}

%new
- (void)recalculateItemLayouts {
    if (!_gIsFiveColumnsEnabled) return;

    CGFloat edgeSize = OMIGetDoubleIvar2(self, @"_itemEdgeSize", @"itemEdgeSize", 0);
    CGFloat itemSpacing = OMIGetDoubleIvar2(self, @"_itemSpacing", @"itemSpacing", 0);
    if (edgeSize <= 0 || itemSpacing <= 0) return;

    CGFloat totalWidth = edgeSize * 4 + itemSpacing * 3;
    CGFloat newItemSpacing = itemSpacing * _gCCUIGlobalIconScale;
    CGFloat newEdgeSize = (totalWidth - newItemSpacing * 4) / 5;
    if (newEdgeSize <= 0) return;

    OMISetDoubleIvar2(self, @"_itemEdgeSize", @"itemEdgeSize", newEdgeSize);
    OMISetDoubleIvar2(self, @"_itemSpacing", @"itemSpacing", newItemSpacing);
}

%end

%end // FiveColumnSizingGroup

#pragma mark - Group: five-column packing (功能 2 辅助)

%group FiveColumnPackingGroup

%hook CCUIControlCenterPositionProviderPackingRule

- (id)initWithPackFrom:(unsigned long long)arg1
    packingOrder:(unsigned long long)arg2
    sizeLimit:(CCUILayoutSize)arg3
{
    if (!_gIsFiveColumnsEnabled) return %orig;
    if (arg3.width < 10) arg3.width = 5;
    if (arg3.height < 10) arg3.height = 4;
    return %orig;
}

%end

%hook CCUIControlCenterPositionProvider

- (id)_generateRectByIdentifierWithOrderedIdentifiers:(NSArray<NSString *> *)identifiers
    orderedSizes:(NSArray<NSValue *> *)sizes
    packingOrder:(unsigned long long)arg3
    startPosition:(CCUILayoutPoint)arg4
    maximumSize:(CCUILayoutSize)arg5
    outputLayoutSize:(CCUILayoutSize *)arg6
{
    if (!_gIsFiveColumnsEnabled) return %orig;
    if (arg5.width < 10) arg5.width = 5;
    if (arg5.height < 10) arg5.height = 4;
    return %orig;
}

- (void)regenerateRectsWithOrderedIdentifiers:(NSArray<NSString *> *)identifiers
                                orderedSizes:(NSArray<NSValue *> *)sizes
{
    if (!_gIsFiveColumnsEnabled) { %orig; return; }
    %orig(identifiers, sizes);
}

%end

%end // FiveColumnPackingGroup

#pragma mark - Group: five-column cosmetics

%group FiveColumnCosmeticsGroup

%hook CCUIButtonModuleView

- (void)didMoveToWindow {
    %orig;
    if (!_gIsFiveColumnsEnabled) return;

    for (UIView *subview in self.subviews) {
        if (OMIIsKindOf(subview, "CCUICAPackageView") || OMIIsKindOf(subview, "UIImage")) {
            subview.transform = CGAffineTransformMakeScale(_gCCUIGlobalIconScale, _gCCUIGlobalIconScale);
        }
    }

    UIView *highlightedView = OMIGetViewIvar(self, @"_highlightedBackgroundView", @"highlightedBackgroundView");
    OMISetContinuousCornerRadius(highlightedView, _gCCUIGlobalCornerRadius);
}

- (void)_setGlyphImage:(UIImage *)image {
    if (!_gIsFiveColumnsEnabled || !image) { %orig; return; }

    CGFloat scale = _gCCUIGlobalIconScale;
    CGSize target = CGSizeMake(image.size.width * scale, image.size.height * scale);
    if (target.width <= 0 || target.height <= 0) { %orig; return; }

    UIGraphicsBeginImageContextWithOptions(target, NO, image.scale);
    [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    UIImage *scaledImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    %orig(scaledImage ?: image);
}

%end

%hook CCUIBaseSliderView

- (void)didMoveToWindow {
    %orig;
    if (!_gIsFiveColumnsEnabled) return;
    for (UIView *subview in self.subviews) {
        if (OMIIsKindOf(subview, "CCUICAPackageView")) {
            subview.transform = CGAffineTransformMakeScale(_gCCUIGlobalIconScale, _gCCUIGlobalIconScale);
        }
    }
}

%end

%hook CCUILabeledRoundButton

- (void)didMoveToWindow {
    %orig;
    if (_gIsFiveColumnsEnabled) {
        self.transform = CGAffineTransformMakeScale(_gCCUIGlobalIconScale, _gCCUIGlobalIconScale);
    }
}

- (void)layoutSubviews {
    %orig;
    if (!_gIsFiveColumnsEnabled) return;
    for (UIView *subview in self.subviews) {
        CGRect f = subview.frame;
        subview.frame = CGRectMake(f.origin.x, f.origin.y + 3, f.size.width, f.size.height);
    }
}

%end

%hook CCUIContentModuleContainerViewController

- (CGFloat)_continuousCornerRadiusForCompactState {
    if (!_gIsFiveColumnsEnabled) return %orig;
    return _gCCUIGlobalCornerRadius;
}

%end

%hook CCUIContinuousSliderView

- (void)setContinuousSliderCornerRadius:(CGFloat)arg1 {
    if (_gIsFiveColumnsEnabled && arg1 >= 19 && arg1 <= 22) {
        arg1 = _gCCUIGlobalCornerRadius;
    }
    %orig;
}

- (void)didMoveToWindow {
    %orig;
    if (!_gIsFiveColumnsEnabled) return;
    UIView *backgroundView = OMIGetViewIvar(self, @"_backgroundView", @"backgroundView");
    OMISetContinuousCornerRadius(backgroundView, _gCCUIGlobalCornerRadius);
}

%end

%end // FiveColumnCosmeticsGroup

#pragma mark - Group: global UIView corner radius (iOS 17 高危，单独隔离)

%group CornerRadiusGroup

%hook UIView

- (void)_setContinuousCornerRadius:(CGFloat)arg1 {
    if (_gIsFiveColumnsEnabled && (arg1 >= 19 && arg1 <= 22) && OMIIsKindOf(self, "MTMaterialView")) {
        arg1 = _gCCUIGlobalCornerRadius;
    }
    %orig;
}

%end

%end // CornerRadiusGroup

#pragma mark - Group: MediaControls

%group MediaControlsGroup

%hook MRUTransportButton

- (void)didMoveToWindow {
    %orig;
    if (_gIsFiveColumnsEnabled) {
        self.transform = CGAffineTransformMakeScale(_gCCUIGlobalIconScale, _gCCUIGlobalIconScale);
    }
}

%end

%hook MRUNowPlayingLabelView

- (void)layoutSubviews {
    %orig;
    if (!_gIsFiveColumnsEnabled) return;

    if ([self respondsToSelector:@selector(layout)] && self.layout != 0) return;

    UILabel *label = nil;

    if ([self respondsToSelector:@selector(placeholderLabel)]) {
        label = (UILabel *)self.placeholderLabel;
    } else if ([self respondsToSelector:@selector(placeholderMarqueeView)]) {
        label = (UILabel *)self.placeholderMarqueeView;
    }
    if ([label isKindOfClass:[UILabel class]]) label.font = [label.font fontWithSize:_gCCUIGlobalFontSize];

    label = nil;
    if ([self respondsToSelector:@selector(titleLabel)]) {
        label = (UILabel *)self.titleLabel;
    } else if ([self respondsToSelector:@selector(titleMarqueeView)]) {
        label = (UILabel *)self.titleMarqueeView;
    }
    if ([label isKindOfClass:[UILabel class]]) label.font = [label.font fontWithSize:_gCCUIGlobalFontSize];

    label = nil;
    if ([self respondsToSelector:@selector(subtitleLabel)]) {
        label = (UILabel *)self.subtitleLabel;
    } else if ([self respondsToSelector:@selector(subtitleMarqueeView)]) {
        label = (UILabel *)self.subtitleMarqueeView;
    }
    if ([label isKindOfClass:[UILabel class]]) label.font = [label.font fontWithSize:_gCCUIGlobalFontSize];
}

%end

%hook MRUNowPlayingRoutingButton

- (void)didMoveToWindow {
    %orig;
    if (!_gIsFiveColumnsEnabled) return;
    for (UIView *subview in self.subviews) {
        if (OMIIsKindOf(subview, "CCUICAPackageView")) {
            subview.transform = CGAffineTransformMakeScale(_gCCUIGlobalIconScale, _gCCUIGlobalIconScale);
        }
    }
}

%end

%hook MRUNowPlayingHeaderView

- (void)layoutSubviews {
    %orig;
    if (!_gIsFiveColumnsEnabled) return;
    if (![self respondsToSelector:@selector(labelView)]) return;
    UIView *labelView = self.labelView;
    if (!labelView) return;
    CGRect f = labelView.frame;
    labelView.frame = CGRectMake(f.origin.x, f.origin.y + 6, f.size.width, f.size.height);
}

%end

%end // MediaControlsGroup

#pragma mark - Groups: lazily loaded modules

%group ConnectivityModuleGroup

%hook CCUIConnectivityModuleViewController

- (void)viewWillLayoutSubviews {
    %orig;
    if (!_gIsFiveColumnsEnabled) return;

    BOOL expanded = NO;
    if ([self respondsToSelector:@selector(isExpanded)]) expanded = self.expanded;
    UIEdgeInsets inset = expanded ? UIEdgeInsetsZero : UIEdgeInsetsMake(-6, -9, 0, 0);
    for (UIView *subview in self.view.subviews) {
        if ([subview isKindOfClass:[UIScrollView class]]) {
            ((UIScrollView *)subview).contentInset = inset;
        }
    }
}

%end

%end // ConnectivityModuleGroup

%group FocusUIModuleGroup

%hook FCCCModuleViewController

- (void)viewWillLayoutSubviews {
    %orig;
    if (!_gIsFiveColumnsEnabled) return;
    for (UIView *subview in self.view.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)subview;
            label.font = [label.font fontWithSize:_gCCUIGlobalFontSize];
        }
    }
}

%end

%end // FocusUIModuleGroup

%group HearingAidsModuleGroup

%hook HACCIconViewController

- (void)viewDidLoad {
    %orig;
    if (_gIsFiveColumnsEnabled) {
        self.view.transform = CGAffineTransformMakeScale(_gCCUIGlobalIconScale, _gCCUIGlobalIconScale);
    }
}

%end

%end // HearingAidsModuleGroup

#pragma mark - Guarded, lazy group initialisation

static BOOL gInitInsets = NO;
static BOOL gInitSizing = NO;
static BOOL gInitPacking = NO;
static BOOL gInitCosmetics = NO;
static BOOL gInitCorner = NO;
static BOOL gInitMedia = NO;
static BOOL gInitConnectivity = NO;
static BOOL gInitFocus = NO;
static BOOL gInitHearing = NO;

static void OMITryInitGroups(void) {
    // 1. 状态栏内边距（功能 1）
    if (!gInitInsets) {
        static const OMIRequirement reqs[] = {
            {"CCUIStatusBar", "setCompactEdgeInsets:"},
            {"CCUIStatusBar", "setExpandedEdgeInsets:"},
        };
        if (OMIRequirementsMet(reqs, sizeof(reqs) / sizeof(reqs[0])) &&
            OMIArg2IsStruct("CCUIStatusBar", "setCompactEdgeInsets:") &&
            OMIArg2IsStruct("CCUIStatusBar", "setExpandedEdgeInsets:")) {
            %init(StatusBarInsetsGroup);
            gInitInsets = YES;
            OMILog(@"StatusBarInsetsGroup installed");
        }
    }

    // 2. 五列尺寸重算（功能 2 核心，单独成组，避免被其它类拖累）
    if (!gInitSizing) {
        static const OMIRequirement reqs[] = {
            {"CCUIMutableLayoutOptions", "setItemEdgeSize:"},
            {"CCUIMutableLayoutOptions", "setItemSpacing:"},
        };
        if (OMIRequirementsMet(reqs, sizeof(reqs) / sizeof(reqs[0]))) {
            %init(FiveColumnSizingGroup);
            gInitSizing = YES;
            OMILog(@"FiveColumnSizingGroup installed");
        }
    }

    // 3. 五列排布辅助
    if (!gInitPacking) {
        static const OMIRequirement reqs[] = {
            {"CCUIControlCenterPositionProviderPackingRule", "initWithPackFrom:packingOrder:sizeLimit:"},
            {"CCUIControlCenterPositionProvider", "_generateRectByIdentifierWithOrderedIdentifiers:orderedSizes:packingOrder:startPosition:maximumSize:outputLayoutSize:"},
            {"CCUIControlCenterPositionProvider", "regenerateRectsWithOrderedIdentifiers:orderedSizes:"},
        };
        if (OMIRequirementsMet(reqs, sizeof(reqs) / sizeof(reqs[0]))) {
            %init(FiveColumnPackingGroup);
            gInitPacking = YES;
            OMILog(@"FiveColumnPackingGroup installed");
        }
    }

    // 4. 五列配套外观
    if (!gInitCosmetics) {
        static const OMIRequirement reqs[] = {
            {"CCUIButtonModuleView", "didMoveToWindow"},
            {"CCUIButtonModuleView", "_setGlyphImage:"},
            {"CCUIBaseSliderView", "didMoveToWindow"},
            {"CCUILabeledRoundButton", "didMoveToWindow"},
            {"CCUILabeledRoundButton", "layoutSubviews"},
            {"CCUIContentModuleContainerViewController", "_continuousCornerRadiusForCompactState"},
            {"CCUIContinuousSliderView", "setContinuousSliderCornerRadius:"},
            {"CCUIContinuousSliderView", "didMoveToWindow"},
        };
        if (OMIRequirementsMet(reqs, sizeof(reqs) / sizeof(reqs[0]))) {
            %init(FiveColumnCosmeticsGroup);
            gInitCosmetics = YES;
            OMILog(@"FiveColumnCosmeticsGroup installed");
        }
    }

    // 5. 全局 UIView 圆角 hook：单独隔离 + 要求 MaterialKit 已加载。
    //    iOS 17 上这个私有方法最容易被移除，是原版进安全模式的高危点。
    if (!gInitCorner) {
        static const OMIRequirement reqs[] = {
            {"UIView", "_setContinuousCornerRadius:"},
        };
        if (objc_getClass("MTMaterialView") &&
            OMIRequirementsMet(reqs, sizeof(reqs) / sizeof(reqs[0]))) {
            %init(CornerRadiusGroup);
            gInitCorner = YES;
            OMILog(@"CornerRadiusGroup installed");
        }
    }

    // 6. 媒体控制
    if (!gInitMedia) {
        static const OMIRequirement reqs[] = {
            {"MRUTransportButton", "didMoveToWindow"},
            {"MRUNowPlayingLabelView", "layoutSubviews"},
            {"MRUNowPlayingRoutingButton", "didMoveToWindow"},
            {"MRUNowPlayingHeaderView", "layoutSubviews"},
        };
        if (OMIRequirementsMet(reqs, sizeof(reqs) / sizeof(reqs[0]))) {
            %init(MediaControlsGroup);
            gInitMedia = YES;
            OMILog(@"MediaControlsGroup installed");
        }
    }

    // 7-9. 按需加载的模块
    if (!gInitConnectivity) {
        static const OMIRequirement reqs[] = {{"CCUIConnectivityModuleViewController", "viewWillLayoutSubviews"}};
        if (OMIRequirementsMet(reqs, 1)) {
            %init(ConnectivityModuleGroup);
            gInitConnectivity = YES;
            OMILog(@"ConnectivityModuleGroup installed");
        }
    }
    if (!gInitFocus) {
        static const OMIRequirement reqs[] = {{"FCCCModuleViewController", "viewWillLayoutSubviews"}};
        if (OMIRequirementsMet(reqs, 1)) {
            %init(FocusUIModuleGroup);
            gInitFocus = YES;
            OMILog(@"FocusUIModuleGroup installed");
        }
    }
    if (!gInitHearing) {
        static const OMIRequirement reqs[] = {{"HACCIconViewController", "viewDidLoad"}};
        if (OMIRequirementsMet(reqs, 1)) {
            %init(HearingAidsModuleGroup);
            gInitHearing = YES;
            OMILog(@"HearingAidsModuleGroup installed");
        }
    }

    OMIUpdateStatus();
}

static void OMIUpdateStatus(void) {
    NSString *status = [NSString stringWithFormat:
        @"iOS %@ | 边距=%@ 五列=%@ 排布=%@ 外观=%@ 圆角=%@ 媒体=%@ 连接=%@ 专注=%@ 助听=%@",
        [[UIDevice currentDevice] systemVersion],
        gInitInsets ? @"ok" : @"no", gInitSizing ? @"ok" : @"no",
        gInitPacking ? @"ok" : @"no", gInitCosmetics ? @"ok" : @"no",
        gInitCorner ? @"ok" : @"no", gInitMedia ? @"ok" : @"no",
        gInitConnectivity ? @"ok" : @"no", gInitFocus ? @"ok" : @"no",
        gInitHearing ? @"ok" : @"no"];
    OMISetDiagnostic(@"omiStatus", status);
}

#pragma mark - Constructor

static void OMIBundleDidLoadCallback(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    // hook 安装统一放主线程，避免与 SpringBoard UI 初始化竞争
    dispatch_async(dispatch_get_main_queue(), ^{
        OMITryInitGroups();
    });
}

%ctor {
    @autoreleasepool {
        OMILog(@"loaded, iOS %@", [[UIDevice currentDevice] systemVersion]);
        OMISetDiagnostic(@"omiMissing", @"");
        gMissing = [NSMutableString new];

        // SpringBoard 的类和方法一定存在，单独一组无条件安装
        %init(SpringBoardGroup);

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetLocalCenter(), NULL, OMIBundleDidLoadCallback,
            (CFStringRef)NSBundleDidLoadNotification, NULL,
            CFNotificationSuspensionBehaviorCoalesce);

        OMITryInitGroups();

        // 部分私有框架不会发 NSBundleDidLoadNotification，延时兜底重试
        for (NSNumber *delay in @[@0.5, @2.0, @5.0, @10.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([delay doubleValue] * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ OMITryInitGroups(); });
        }
    }
}
