#import "MGColorPicker.h"
#import "MGSettings.h"
#include <math.h>

@interface MGColorWheel : UIControl
@property (nonatomic) CGFloat hue, saturation, brightness;
- (UIColor *)color;
- (void)setColor:(UIColor *)color;
@end
@implementation MGColorWheel {
    UIImage *_wheel;
    CGFloat _diameter;
    UIView *_marker;
}
- (instancetype)init {
    if ((self=[super init])) {
        self.brightness=1; self.opaque=NO; self.backgroundColor=UIColor.clearColor;
        self.isAccessibilityElement=YES;
        self.accessibilityLabel=@"Color wheel"; self.accessibilityHint=@"Drag to choose hue and saturation. Use brightness below for lighter or darker colors.";
        _marker=[UIView new]; _marker.userInteractionEnabled=NO; _marker.layer.cornerRadius=11; _marker.layer.borderWidth=2; _marker.layer.borderColor=UIColor.whiteColor.CGColor; _marker.layer.shadowColor=UIColor.blackColor.CGColor; _marker.layer.shadowOpacity=.5; _marker.layer.shadowRadius=2; _marker.layer.shadowOffset=CGSizeZero; [self addSubview:_marker];
    } return self;
}
- (UIColor *)color { return [UIColor colorWithHue:self.hue saturation:self.saturation brightness:self.brightness alpha:1]; }
- (void)setColor:(UIColor *)color {
    CGFloat h=0,s=0,b=1;
    if (![color getHue:&h saturation:&s brightness:&b alpha:NULL]) [color getWhite:&b alpha:NULL];
    self.hue=h; self.saturation=s; self.brightness=b; [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat diameter=MIN(self.bounds.size.width,self.bounds.size.height);
    if (diameter>0 && diameter!=_diameter) {
        _diameter=diameter;
        UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat]; format.opaque=NO; format.scale=MIN(2,512/diameter);
        UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(diameter,diameter) format:format];
        _wheel=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            CGPoint centre=CGPointMake(diameter/2,diameter/2); CGFloat radius=diameter/2;
            for (NSUInteger degree=0; degree<360; degree++) {
                CGFloat start=degree*M_PI/180, end=(degree+1.6)*M_PI/180;
                UIBezierPath *wedge=[UIBezierPath bezierPath]; [wedge moveToPoint:centre]; [wedge addArcWithCenter:centre radius:radius startAngle:start endAngle:end clockwise:YES]; [wedge closePath];
                [[UIColor colorWithHue:degree/360.0 saturation:1 brightness:1 alpha:1] setFill]; [wedge fill];
            }
            CGContextRef canvas=context.CGContext; CGContextSaveGState(canvas);
            CGContextAddEllipseInRect(canvas,CGRectMake(0,0,diameter,diameter)); CGContextClip(canvas);
            CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB(); CGFloat components[]={1,1,1,1, 1,1,1,0}, locations[]={0,1};
            CGGradientRef gradient=CGGradientCreateWithColorComponents(space,components,locations,2);
            if (gradient) { CGContextDrawRadialGradient(canvas,gradient,centre,0,centre,radius,0); CGGradientRelease(gradient); }
            CGColorSpaceRelease(space); CGContextRestoreGState(canvas);
        }];
        [self setNeedsDisplay];
    }
    CGFloat radius=diameter/2, angle=self.hue*2*M_PI;
    CGPoint centre=CGPointMake(CGRectGetMidX(self.bounds),CGRectGetMidY(self.bounds));
    _marker.frame=CGRectMake(centre.x+cos(angle)*self.saturation*radius-11,centre.y+sin(angle)*self.saturation*radius-11,22,22); _marker.backgroundColor=self.color;
    self.accessibilityValue=MGHexForColor(self.color);
}
- (void)drawRect:(CGRect)rect { (void)rect; [_wheel drawInRect:CGRectMake((self.bounds.size.width-_diameter)/2,(self.bounds.size.height-_diameter)/2,_diameter,_diameter)]; }
- (void)selectPoint:(CGPoint)point {
    CGFloat dx=point.x-CGRectGetMidX(self.bounds), dy=point.y-CGRectGetMidY(self.bounds), radius=MIN(self.bounds.size.width,self.bounds.size.height)/2;
    if (radius<=0) return; CGFloat angle=atan2(dy,dx)/(2*M_PI);
    self.hue=angle<0 ? angle+1 : angle; self.saturation=MIN(1,hypot(dx,dy)/radius); [self setNeedsLayout]; [self sendActionsForControlEvents:UIControlEventValueChanged];
}
- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event { (void)event; if (self.brightness<.001) self.brightness=1; [self selectPoint:[touch locationInView:self]]; return YES; }
- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event { (void)event; [self selectPoint:[touch locationInView:self]]; return YES; }
@end

@interface MGColorPickerViewController () <UITextFieldDelegate>
@end
@implementation MGColorPickerViewController {
    NSString *_key;
    MGColorWheel *_wheel;
    UISlider *_brightness;
    UIScrollView *_scroll;
    UITextField *_hex;
    UILabel *_value, *_error;
    UIView *_swatch;
}
- (instancetype)initWithPreference:(NSString *)key title:(NSString *)title {
    if ((self=[super init])) { _key=[key copy]; self.title=title; } return self;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=MGBackgroundColor();
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Apply" style:UIBarButtonItemStyleDone target:self action:@selector(apply)];
    _scroll=[UIScrollView new]; _scroll.translatesAutoresizingMaskIntoConstraints=NO; _scroll.keyboardDismissMode=UIScrollViewKeyboardDismissModeInteractive; [self.view addSubview:_scroll];
    UIStackView *stack=[UIStackView new]; stack.translatesAutoresizingMaskIntoConstraints=NO; stack.axis=UILayoutConstraintAxisVertical; stack.spacing=18; stack.alignment=UIStackViewAlignmentFill; [_scroll addSubview:stack];
    UILabel *hint=[UILabel new]; hint.text=@"Choose a color on the wheel, then adjust brightness. You can also enter a hex color below."; hint.numberOfLines=0; hint.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody]; hint.textColor=MGTextColor(); [stack addArrangedSubview:hint];
    UIView *wheelHolder=[UIView new]; [stack addArrangedSubview:wheelHolder];
    _wheel=[MGColorWheel new]; _wheel.translatesAutoresizingMaskIntoConstraints=NO; [wheelHolder addSubview:_wheel];
    UIColor *initial=[_key isEqualToString:@"accentHex"] ? MGAccentColor() : [_key isEqualToString:@"backgroundHex"] ? MGBackgroundColor() : MGTextColor();
    [_wheel setColor:initial]; [_wheel addTarget:self action:@selector(wheelChanged) forControlEvents:UIControlEventValueChanged];
    _value=[UILabel new]; _value.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody]; _value.textColor=MGTextColor(); [stack addArrangedSubview:_value];
    _brightness=[UISlider new]; _brightness.minimumValue=0; _brightness.maximumValue=1; _brightness.value=_wheel.brightness; _brightness.minimumTrackTintColor=MGAccentColor(); _brightness.accessibilityLabel=@"Color brightness"; [_brightness addTarget:self action:@selector(brightnessChanged) forControlEvents:UIControlEventValueChanged]; [stack addArrangedSubview:_brightness];
    UIStackView *hexRow=[UIStackView new]; hexRow.spacing=12; hexRow.alignment=UIStackViewAlignmentCenter; [stack addArrangedSubview:hexRow];
    _swatch=[UIView new]; _swatch.layer.cornerRadius=10; _swatch.layer.borderWidth=.5; _swatch.layer.borderColor=[MGTextColor() colorWithAlphaComponent:.3].CGColor; [hexRow addArrangedSubview:_swatch];
    _hex=[UITextField new]; _hex.delegate=self; _hex.borderStyle=UITextBorderStyleRoundedRect; _hex.textColor=MGTextColor(); _hex.backgroundColor=MGSurfaceColor(); _hex.font=[UIFont monospacedSystemFontOfSize:20 weight:UIFontWeightMedium]; _hex.autocorrectionType=UITextAutocorrectionTypeNo; _hex.autocapitalizationType=UITextAutocapitalizationTypeAllCharacters; _hex.keyboardType=UIKeyboardTypeASCIICapable; _hex.returnKeyType=UIReturnKeyDone; _hex.accessibilityLabel=@"Hex color"; [_hex addTarget:self action:@selector(hexChanged) forControlEvents:UIControlEventEditingChanged]; [hexRow addArrangedSubview:_hex];
    _error=[UILabel new]; _error.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; _error.textColor=MGTextColor(); _error.numberOfLines=0; [stack addArrangedSubview:_error];
    [NSLayoutConstraint activateConstraints:@[
      [_scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor], [_scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor], [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
      [stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:18], [stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-18], [stack.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor constant:20], [stack.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor constant:-20], [stack.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor constant:-40],
      [_wheel.topAnchor constraintEqualToAnchor:wheelHolder.topAnchor constant:12], [_wheel.bottomAnchor constraintEqualToAnchor:wheelHolder.bottomAnchor constant:-12], [_wheel.centerXAnchor constraintEqualToAnchor:wheelHolder.centerXAnchor], [_wheel.widthAnchor constraintLessThanOrEqualToConstant:300], [_wheel.widthAnchor constraintLessThanOrEqualToAnchor:wheelHolder.widthAnchor constant:-24], [_wheel.heightAnchor constraintEqualToAnchor:_wheel.widthAnchor],
      [_swatch.widthAnchor constraintEqualToConstant:44], [_swatch.heightAnchor constraintEqualToConstant:44], [_hex.heightAnchor constraintEqualToConstant:44]]];
    NSLayoutConstraint *width=[_wheel.widthAnchor constraintEqualToAnchor:wheelHolder.widthAnchor constant:-24]; width.priority=UILayoutPriorityDefaultHigh; width.active=YES;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [self updateControls:YES];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.navigationController setNavigationBarHidden:NO animated:animated]; [self.navigationController setToolbarHidden:YES animated:animated]; self.navigationController.interactivePopGestureRecognizer.enabled=YES; }
- (void)updateControls:(BOOL)hex {
    UIColor *color=_wheel.color; _swatch.backgroundColor=color; _brightness.value=_wheel.brightness;
    _value.text=[NSString stringWithFormat:@"Brightness  %.0f%%",_wheel.brightness*100];
    if (hex) _hex.text=MGHexForColor(color); _error.text=@"Hex accepts six digits, with or without #."; [_wheel setNeedsLayout];
}
- (void)wheelChanged { [_hex resignFirstResponder]; [self updateControls:YES]; }
- (void)brightnessChanged { _wheel.brightness=_brightness.value; [self updateControls:YES]; }
- (BOOL)readHex {
    NSString *value=[_hex.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([value hasPrefix:@"#"]) value=[value substringFromIndex:1];
    if (value.length!=6 || [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]].location!=NSNotFound) return NO;
    unsigned int rgb=0; [[NSScanner scannerWithString:value] scanHexInt:&rgb];
    [_wheel setColor:[UIColor colorWithRed:((rgb>>16)&255)/255.0 green:((rgb>>8)&255)/255.0 blue:(rgb&255)/255.0 alpha:1]]; return YES;
}
- (void)hexChanged { if ([self readHex]) [self updateControls:NO]; }
- (BOOL)textFieldShouldReturn:(UITextField *)field { if ([self readHex]) { [field resignFirstResponder]; [self updateControls:YES]; } else _error.text=@"Enter a valid six-digit hex color."; return YES; }
- (void)apply {
    if (![self readHex]) { _error.text=@"Enter a valid six-digit hex color."; return; }
    NSMutableDictionary *colors=[@{@"theme":@"custom", @"accentHex":[MGHexForColor(MGAccentColor()) substringFromIndex:1], @"backgroundHex":[MGHexForColor(MGBackgroundColor()) substringFromIndex:1], @"textHex":[MGHexForColor(MGTextColor()) substringFromIndex:1]} mutableCopy]; colors[_key]=[MGHexForColor(_wheel.color) substringFromIndex:1];
    if ([[MGSettings shared] applyAppearance:colors]) [self.navigationController popViewControllerAnimated:YES];
}
- (void)keyboardChanged:(NSNotification *)notification {
    CGRect frame=[notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect local=[self.view convertRect:frame fromView:nil]; CGFloat overlap=MAX(0,CGRectGetMaxY(self.view.bounds)-CGRectGetMinY(local)-self.view.safeAreaInsets.bottom);
    _scroll.contentInset=UIEdgeInsetsMake(0,0,overlap,0); _scroll.verticalScrollIndicatorInsets=_scroll.contentInset;
    if (_hex.isFirstResponder) [_scroll scrollRectToVisible:[_hex convertRect:_hex.bounds toView:_scroll] animated:YES];
}
@end
