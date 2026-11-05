// ShotShotCpp — Objective-C++ порт ShotShot (аналог LightShot).
// Дзеркало main.swift: виділення області + анотації, знімок через
// ScreenCaptureKit, хоткей ⌘⇧7 (Carbon), менюбар-агент ✂︎.
//
// Відмінність від Swift-версії лише в мові/рантаймі: тут немає Swift runtime
// (16 libswift*.dylib), але AppKit + ScreenCaptureKit + Metal лінкуються так
// само — бо резидентний агент показує іконку в менюбарі й малює UI.
//
// Лінкує: Cocoa, Carbon, ScreenCaptureKit.

#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <vector>
#include <utility>
#include <cmath>

// MARK: - Модель анотацій

typedef NS_ENUM(NSInteger, Tool) { ToolArrow, ToolRect, ToolLine, ToolText, ToolMarker };

@interface Annotation : NSObject
@property (nonatomic) Tool tool;
@property (nonatomic, strong) NSColor *color;
@property (nonatomic) CGFloat width;
@property (nonatomic) CGPoint start;
@property (nonatomic) CGPoint end;
@property (nonatomic, strong) NSMutableArray<NSValue *> *points; // для marker (freehand)
@property (nonatomic, copy) NSString *text;
@property (nonatomic) CGFloat fontSize;
@end
@implementation Annotation
- (instancetype)initWithTool:(Tool)tool color:(NSColor *)color width:(CGFloat)width {
    if ((self = [super init])) {
        _tool = tool; _color = color; _width = width;
        _start = CGPointZero; _end = CGPointZero;
        _points = [NSMutableArray array];
        _text = @""; _fontSize = 18;
    }
    return self;
}
@end

// MARK: - Кнопка кольору (замість objc_setAssociatedObject у Swift-версії)

@interface ColorButton : NSButton
@property (nonatomic, strong) NSColor *swatch;
@end
@implementation ColorButton
@end

// MARK: - Вікно оверлея (borderless, може стати key)

@interface OverlayWindow : NSWindow
@end
@implementation OverlayWindow
- (BOOL)canBecomeKeyWindow  { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

// MARK: - В'юха оверлея

typedef NS_ENUM(NSInteger, Phase)      { PhaseSelecting, PhaseAnnotating };
typedef NS_ENUM(NSInteger, HandleKind) { HK_TL, HK_T, HK_TR, HK_R, HK_BR, HK_B, HK_BL, HK_L, HK_None };
typedef NS_ENUM(NSInteger, Mode)       { ModeNone, ModeNewSel, ModeMove, ModeResize, ModeAnnotate };

@interface OverlayView : NSView {
    Phase _phase;
    Mode _mode;
    HandleKind _resizeHandle;
    CGFloat _handleSize;

    BOOL _hasSelection;
    CGRect _selection;
    CGPoint _dragStart;
    BOOL _dragging;
    CGPoint _moveAnchor;
    CGRect _selAtDragStart;

    NSMutableArray<Annotation *> *_annotations;
    Annotation *_current;

    NSView *_toolbar;
    NSTextField *_textEditor;
    BOOL _exporting;
}
@property (nonatomic, strong) NSImage *background;   // заморожений екран
@property (nonatomic) CGFloat backingScale;
@property (nonatomic) Tool tool;
@property (nonatomic, strong) NSColor *color;
@property (nonatomic) CGFloat lineWidth;
@property (nonatomic, copy) void (^onFinish)(void); // закрити оверлей
@end

@implementation OverlayView

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _phase = PhaseSelecting;
        _mode = ModeNone;
        _resizeHandle = HK_None;
        _handleSize = 10;
        _hasSelection = NO;
        _dragging = NO;
        _annotations = [NSMutableArray array];
        _backingScale = 2;
        _tool = ToolArrow;
        _color = [NSColor systemRedColor];
        _lineWidth = 3;
        _exporting = NO;
    }
    return self;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isFlipped { return NO; }   // bottom-left, як NSBezierPath

// MARK: Малювання

- (void)drawRect:(NSRect)dirty {
    // 1) фон — заморожений екран
    [_background drawInRect:self.bounds];

    // 2) затемнення поза виділенням (не для експорту)
    if (!_exporting) {
        [[[NSColor blackColor] colorWithAlphaComponent:0.35] setFill];
        if (_hasSelection) {
            NSBezierPath *p = [NSBezierPath bezierPathWithRect:self.bounds];
            [p appendBezierPath:[[NSBezierPath bezierPathWithRect:_selection] bezierPathByReversingPath]];
            [p fill];
            // рамка виділення
            [[NSColor whiteColor] setStroke];
            NSBezierPath *b = [NSBezierPath bezierPathWithRect:_selection];
            b.lineWidth = 1; [b stroke];
            [self drawDimensionLabel:_selection];
            // ручки для зміни розміру (лише в режимі анотацій)
            if (_phase == PhaseAnnotating) {
                auto centers = [self handleCenters:_selection];
                for (auto &kc : centers) {
                    CGRect r = [self handleRect:kc.second];
                    [[NSColor whiteColor] setFill];
                    [[NSBezierPath bezierPathWithRect:r] fill];
                    [[[NSColor blackColor] colorWithAlphaComponent:0.5] setStroke];
                    NSBezierPath *hp = [NSBezierPath bezierPathWithRect:r];
                    hp.lineWidth = 1; [hp stroke];
                }
            }
        } else {
            NSRectFill(self.bounds);
        }
    }

    // 3) анотації (і в експорт теж)
    for (Annotation *a in _annotations) [self drawAnnotation:a];
    if (_current) [self drawAnnotation:_current];
}

- (void)drawDimensionLabel:(CGRect)sel {
    NSString *txt = [NSString stringWithFormat:@"%d × %d", (int)sel.size.width, (int)sel.size.height];
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor whiteColor]
    };
    NSAttributedString *s = [[NSAttributedString alloc] initWithString:txt attributes:attrs];
    NSSize size = s.size;
    CGPoint o = CGPointMake(CGRectGetMinX(sel), CGRectGetMaxY(sel) + 4);
    if (o.y + size.height > CGRectGetMaxY(self.bounds)) o.y = CGRectGetMaxY(sel) - size.height - 4;
    CGRect bg = CGRectMake(o.x - 4, o.y - 2, size.width + 8, size.height + 4);
    [[[NSColor blackColor] colorWithAlphaComponent:0.6] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bg xRadius:3 yRadius:3] fill];
    [s drawAtPoint:o];
}

- (void)drawAnnotation:(Annotation *)a {
    [a.color setStroke];
    [a.color setFill];
    switch (a.tool) {
        case ToolRect: {
            CGRect r = CGRectMake(MIN(a.start.x, a.end.x), MIN(a.start.y, a.end.y),
                                  fabs(a.end.x - a.start.x), fabs(a.end.y - a.start.y));
            NSBezierPath *p = [NSBezierPath bezierPathWithRect:r];
            p.lineWidth = a.width; [p stroke];
            break;
        }
        case ToolLine: {
            NSBezierPath *p = [NSBezierPath bezierPath];
            p.lineWidth = a.width; p.lineCapStyle = NSLineCapStyleRound;
            [p moveToPoint:a.start]; [p lineToPoint:a.end]; [p stroke];
            break;
        }
        case ToolArrow:
            [self drawArrowFrom:a.start to:a.end width:a.width];
            break;
        case ToolMarker: {
            if (a.points.count <= 1) break;
            NSBezierPath *p = [NSBezierPath bezierPath];
            p.lineWidth = a.width;
            p.lineCapStyle = NSLineCapStyleRound; p.lineJoinStyle = NSLineJoinStyleRound;
            [p moveToPoint:a.points[0].pointValue];
            for (NSUInteger i = 1; i < a.points.count; i++) [p lineToPoint:a.points[i].pointValue];
            [[a.color colorWithAlphaComponent:0.4] setStroke];
            [p stroke];
            break;
        }
        case ToolText: {
            NSDictionary *attrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:a.fontSize weight:NSFontWeightSemibold],
                NSForegroundColorAttributeName: a.color
            };
            [[[NSAttributedString alloc] initWithString:a.text attributes:attrs] drawAtPoint:a.start];
            break;
        }
    }
}

- (void)drawArrowFrom:(CGPoint)s to:(CGPoint)e width:(CGFloat)width {
    NSBezierPath *path = [NSBezierPath bezierPath]; path.lineWidth = width;
    path.lineCapStyle = NSLineCapStyleRound; path.lineJoinStyle = NSLineJoinStyleRound;
    [path moveToPoint:s]; [path lineToPoint:e];
    CGFloat angle = atan2(e.y - s.y, e.x - s.x);
    CGFloat len = MAX(14, width * 4), spread = M_PI / 7;
    CGPoint p1 = CGPointMake(e.x - len * cos(angle - spread), e.y - len * sin(angle - spread));
    CGPoint p2 = CGPointMake(e.x - len * cos(angle + spread), e.y - len * sin(angle + spread));
    [path moveToPoint:e]; [path lineToPoint:p1];
    [path moveToPoint:e]; [path lineToPoint:p2];
    [path stroke];
}

// MARK: Миша

- (void)resetCursorRects {
    if (_phase == PhaseSelecting) [self addCursorRect:self.bounds cursor:[NSCursor crosshairCursor]];
}

- (void)mouseDown:(NSEvent *)event {
    CGPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (_phase == PhaseSelecting) {
        _dragStart = p; _dragging = YES; _selection = CGRectZero; _hasSelection = YES; _mode = ModeNewSel;
        return;
    }
    // phase == annotating
    [self commitTextEditorIfAny];
    if (_hasSelection) {
        HandleKind h = [self hitHandle:p inRect:_selection];
        if (h != HK_None) { _mode = ModeResize; _resizeHandle = h; _selAtDragStart = _selection; return; }
        if ([self nearBorder:p rect:_selection]) { _mode = ModeMove; _moveAnchor = p; _selAtDragStart = _selection; return; }
    }
    if (_tool == ToolText) { [self beginTextInputAt:p]; _mode = ModeNone; return; }
    Annotation *a = [[Annotation alloc] initWithTool:_tool color:_color width:(_tool == ToolMarker ? 14 : _lineWidth)];
    a.start = p; a.end = p;
    if (_tool == ToolMarker) [a.points addObject:[NSValue valueWithPoint:p]];
    _current = a; _mode = ModeAnnotate;
}

- (void)mouseDragged:(NSEvent *)event {
    CGPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    switch (_mode) {
        case ModeNewSel:
            _selection = CGRectMake(MIN(_dragStart.x, p.x), MIN(_dragStart.y, p.y),
                                    fabs(p.x - _dragStart.x), fabs(p.y - _dragStart.y));
            _hasSelection = YES;
            break;
        case ModeResize:
            _selection = [self resized:_selAtDragStart handle:_resizeHandle point:p];
            break;
        case ModeMove:
            _selection = [self moved:_selAtDragStart byX:(p.x - _moveAnchor.x) byY:(p.y - _moveAnchor.y)];
            break;
        case ModeAnnotate:
            if (_current) { _current.end = p; if (_current.tool == ToolMarker) [_current.points addObject:[NSValue valueWithPoint:p]]; }
            break;
        case ModeNone:
            break;
    }
    self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent *)event {
    switch (_mode) {
        case ModeNewSel:
            _dragging = NO;
            if (_hasSelection && _selection.size.width > 5 && _selection.size.height > 5) {
                _phase = PhaseAnnotating;
                [[NSCursor arrowCursor] set];
                [self showToolbarFor:_selection];
            } else {
                _hasSelection = NO;
            }
            break;
        case ModeResize:
        case ModeMove:
            [self positionToolbar];
            break;
        case ModeAnnotate:
            if (_current) { [_annotations addObject:_current]; _current = nil; }
            break;
        case ModeNone:
            break;
    }
    _mode = ModeNone;
    self.needsDisplay = YES;
}

// MARK: Геометрія ручок / переміщення / розміру

- (std::vector<std::pair<HandleKind, CGPoint>>)handleCenters:(CGRect)s {
    return {
        {HK_TL, CGPointMake(CGRectGetMinX(s), CGRectGetMaxY(s))},
        {HK_T,  CGPointMake(CGRectGetMidX(s), CGRectGetMaxY(s))},
        {HK_TR, CGPointMake(CGRectGetMaxX(s), CGRectGetMaxY(s))},
        {HK_R,  CGPointMake(CGRectGetMaxX(s), CGRectGetMidY(s))},
        {HK_BR, CGPointMake(CGRectGetMaxX(s), CGRectGetMinY(s))},
        {HK_B,  CGPointMake(CGRectGetMidX(s), CGRectGetMinY(s))},
        {HK_BL, CGPointMake(CGRectGetMinX(s), CGRectGetMinY(s))},
        {HK_L,  CGPointMake(CGRectGetMinX(s), CGRectGetMidY(s))},
    };
}
- (CGRect)handleRect:(CGPoint)c {
    return CGRectMake(c.x - _handleSize/2, c.y - _handleSize/2, _handleSize, _handleSize);
}
- (HandleKind)hitHandle:(CGPoint)p inRect:(CGRect)s {
    auto centers = [self handleCenters:s];
    for (auto &kc : centers) {
        if (CGRectContainsPoint(CGRectInset([self handleRect:kc.second], -3, -3), p)) return kc.first;
    }
    return HK_None;
}
- (BOOL)nearBorder:(CGPoint)p rect:(CGRect)s {
    return CGRectContainsPoint(CGRectInset(s, -6, -6), p) && !CGRectContainsPoint(CGRectInset(s, 6, 6), p);
}
- (CGRect)resized:(CGRect)s handle:(HandleKind)h point:(CGPoint)p {
    CGFloat minX = CGRectGetMinX(s), maxX = CGRectGetMaxX(s), minY = CGRectGetMinY(s), maxY = CGRectGetMaxY(s);
    switch (h) {
        case HK_TL: minX = p.x; maxY = p.y; break;
        case HK_T:  maxY = p.y; break;
        case HK_TR: maxX = p.x; maxY = p.y; break;
        case HK_R:  maxX = p.x; break;
        case HK_BR: maxX = p.x; minY = p.y; break;
        case HK_B:  minY = p.y; break;
        case HK_BL: minX = p.x; minY = p.y; break;
        case HK_L:  minX = p.x; break;
        default: break;
    }
    minX = MAX(0, minX); minY = MAX(0, minY);
    maxX = MIN(self.bounds.size.width, maxX); maxY = MIN(self.bounds.size.height, maxY);
    CGFloat x = MIN(minX, maxX), y = MIN(minY, maxY);
    CGFloat w = MAX(fabs(maxX - minX), 10), hgt = MAX(fabs(maxY - minY), 10);
    return CGRectMake(x, y, w, hgt);
}
- (CGRect)moved:(CGRect)s byX:(CGFloat)dx byY:(CGFloat)dy {
    CGPoint o = CGPointMake(CGRectGetMinX(s) + dx, CGRectGetMinY(s) + dy);
    o.x = MAX(0, MIN(o.x, self.bounds.size.width - s.size.width));
    o.y = MAX(0, MIN(o.y, self.bounds.size.height - s.size.height));
    return CGRectMake(o.x, o.y, s.size.width, s.size.height);
}

// MARK: Клавіатура

- (void)keyDown:(NSEvent *)event {
    if ((int)event.keyCode == 53) { if (_onFinish) _onFinish(); return; } // Esc
    // ⌘C — копіювати виділений скрін (коли вже є зона)
    if ((event.modifierFlags & NSEventModifierFlagCommand) &&
        [[event.charactersIgnoringModifiers lowercaseString] isEqualToString:@"c"] &&
        _phase == PhaseAnnotating && _hasSelection) {
        [self copyShot]; return;
    }
    [super keyDown:event];
}

// MARK: Текстовий інструмент

- (void)beginTextInputAt:(CGPoint)p {
    NSTextField *tf = [[NSTextField alloc] initWithFrame:CGRectMake(p.x, p.y - 6, 200, 24)];
    tf.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    tf.textColor = _color;
    tf.backgroundColor = [NSColor clearColor];
    tf.bordered = NO;
    tf.focusRingType = NSFocusRingTypeNone;
    tf.target = self; tf.action = @selector(textCommitted);
    [self addSubview:tf];
    [self.window makeFirstResponder:tf];
    _textEditor = tf;
}

- (void)textCommitted { [self commitTextEditorIfAny]; }

- (void)commitTextEditorIfAny {
    if (!_textEditor) return;
    NSString *str = _textEditor.stringValue;
    CGPoint origin = CGPointMake(CGRectGetMinX(_textEditor.frame), CGRectGetMinY(_textEditor.frame) + 6);
    [_textEditor removeFromSuperview]; _textEditor = nil;
    if (str.length > 0) {
        Annotation *a = [[Annotation alloc] initWithTool:ToolText color:_color width:_lineWidth];
        a.start = origin; a.text = str; a.fontSize = 18;
        [_annotations addObject:a];
    }
    [self.window makeFirstResponder:self];
    self.needsDisplay = YES;
}

// MARK: Тулбар

- (void)showToolbarFor:(CGRect)sel {
    NSView *bar = [[NSView alloc] initWithFrame:CGRectZero];
    bar.wantsLayer = YES;
    bar.layer.backgroundColor = [NSColor colorWithWhite:0.12 alpha:0.95].CGColor;
    bar.layer.cornerRadius = 8;

    __block CGFloat x = 8;
    void (^addButton)(NSString *, SEL, CGFloat) = ^(NSString *title, SEL sel_, CGFloat width) {
        NSButton *b = [[NSButton alloc] initWithFrame:CGRectMake(x, 6, width, 26)];
        b.title = title; b.bezelStyle = NSBezelStyleRegularSquare; b.bordered = NO;
        b.font = [NSFont systemFontOfSize:15];
        b.contentTintColor = [NSColor whiteColor];
        b.target = self; b.action = sel_;
        [bar addSubview:b]; x += width + 2;
    };
    void (^addColor)(NSColor *) = ^(NSColor *c) {
        ColorButton *b = [[ColorButton alloc] initWithFrame:CGRectMake(x, 9, 20, 20)];
        b.title = @""; b.bordered = NO; b.wantsLayer = YES;
        b.layer.backgroundColor = c.CGColor;
        b.layer.cornerRadius = 10;
        b.swatch = c;
        b.target = self; b.action = @selector(pickColor:);
        [bar addSubview:b]; x += 24;
    };
    void (^sep)(void) = ^{ x += 8; };

    addButton(@"↗", @selector(selArrow), 30);
    addButton(@"▭", @selector(selRect), 30);
    addButton(@"—", @selector(selLine), 30);
    addButton(@"T", @selector(selText), 30);
    addButton(@"🖍", @selector(selMarker), 30);
    sep();
    for (NSColor *c in @[[NSColor systemRedColor], [NSColor systemYellowColor], [NSColor systemGreenColor],
                         [NSColor systemBlueColor], [NSColor blackColor], [NSColor whiteColor]]) addColor(c);
    sep();
    addButton(@"↶", @selector(undo), 30);
    sep();
    addButton(@"📋", @selector(copyShot), 30);
    addButton(@"💾", @selector(saveShot), 30);
    addButton(@"✕", @selector(cancelShot), 30);

    bar.frame = CGRectMake(0, 0, x + 6, 38);
    [self addSubview:bar];
    _toolbar = bar;
    [self positionToolbar];
}

- (void)positionToolbar {
    if (!_toolbar || !_hasSelection) return;
    CGRect sel = _selection;
    CGFloat barW = _toolbar.frame.size.width, barH = _toolbar.frame.size.height;
    CGFloat margin = 8;
    // спершу — під виділенням
    CGFloat by = CGRectGetMinY(sel) - barH - margin;
    if (by < margin) {
        CGFloat above = CGRectGetMaxY(sel) + margin;
        if (above + barH <= CGRectGetMaxY(self.bounds) - margin) by = above;
        else by = CGRectGetMinY(sel) + margin;
    }
    by = MAX(margin, MIN(by, CGRectGetMaxY(self.bounds) - barH - margin));
    CGFloat bx = CGRectGetMinX(sel);
    if (bx + barW > CGRectGetMaxX(self.bounds)) bx = CGRectGetMaxX(self.bounds) - barW - margin;
    if (bx < margin) bx = margin;
    _toolbar.frame = CGRectMake(bx, by, barW, barH);
}

// MARK: Курсори

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *ta in self.trackingAreas) [self removeTrackingArea:ta];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
        options:(NSTrackingActiveAlways | NSTrackingMouseMoved | NSTrackingInVisibleRect)
        owner:self userInfo:nil]];
}

- (void)mouseMoved:(NSEvent *)event {
    CGPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (_phase != PhaseAnnotating || !_hasSelection) { [[NSCursor crosshairCursor] set]; return; }
    HandleKind h = [self hitHandle:p inRect:_selection];
    if (h != HK_None) [[self cursorFor:h] set];
    else if ([self nearBorder:p rect:_selection]) [[NSCursor openHandCursor] set];
    else [[NSCursor arrowCursor] set];
}

- (NSCursor *)cursorFor:(HandleKind)h {
    switch (h) {
        case HK_L: case HK_R: return [NSCursor resizeLeftRightCursor];
        case HK_T: case HK_B: return [NSCursor resizeUpDownCursor];
        default: return [NSCursor crosshairCursor]; // кути (діагональних курсорів нема в публічному API)
    }
}

// MARK: Дії тулбара

- (void)selArrow  { [self commitTextEditorIfAny]; _tool = ToolArrow; }
- (void)selRect   { [self commitTextEditorIfAny]; _tool = ToolRect; }
- (void)selLine   { [self commitTextEditorIfAny]; _tool = ToolLine; }
- (void)selText   { [self commitTextEditorIfAny]; _tool = ToolText; }
- (void)selMarker { [self commitTextEditorIfAny]; _tool = ToolMarker; }
- (void)undo      { if (_annotations.count) { [_annotations removeLastObject]; self.needsDisplay = YES; } }
- (void)pickColor:(ColorButton *)sender { if (sender.swatch) _color = sender.swatch; }
- (void)cancelShot { if (_onFinish) _onFinish(); }

- (void)copyShot {
    NSImage *img = [self exportImage];
    if (!img) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents]; [pb writeObjects:@[img]];
    if (_onFinish) _onFinish();
}

- (void)saveShot {
    NSImage *img = [self exportImage];
    if (!img) return;
    NSData *tiff = img.TIFFRepresentation;
    if (!tiff) return;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:tiff];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png) return;
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd 'at' HH.mm.ss";
    NSString *name = [NSString stringWithFormat:@"Screenshot %@.png", [fmt stringFromDate:[NSDate date]]];
    NSURL *url = [[[NSFileManager.defaultManager homeDirectoryForCurrentUser]
        URLByAppendingPathComponent:@"Desktop"] URLByAppendingPathComponent:name];
    [png writeToURL:url atomically:YES];
    if (_onFinish) _onFinish();
}

// MARK: Експорт виділеної області з анотаціями

- (NSImage *)exportImage {
    [self commitTextEditorIfAny];
    if (!_hasSelection) return nil;
    CGRect sel = _selection;
    _exporting = YES;
    _toolbar.hidden = YES;
    NSBitmapImageRep *rep = [self bitmapImageRepForCachingDisplayInRect:sel];
    if (!rep) { _exporting = NO; _toolbar.hidden = NO; return nil; }
    [self cacheDisplayInRect:sel toBitmapImageRep:rep];
    _exporting = NO;
    _toolbar.hidden = NO;
    NSImage *img = [[NSImage alloc] initWithSize:sel.size];
    [img addRepresentation:rep];
    return img;
}

@end

// MARK: - Контролер захоплення

@interface CaptureController : NSObject
@property (nonatomic, strong) OverlayWindow *window;
+ (instancetype)shared;
- (void)begin;
@end

@implementation CaptureController

+ (instancetype)shared {
    static CaptureController *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[CaptureController alloc] init]; });
    return s;
}

- (void)begin {
    if (self.window) return; // вже відкрито
    [self capture];
}

- (void)capture {
    // екран під курсором
    CGPoint mouse = [NSEvent mouseLocation];
    NSScreen *screen = nil;
    for (NSScreen *s in [NSScreen screens]) if (CGRectContainsPoint(s.frame, mouse)) { screen = s; break; }
    if (!screen) screen = [NSScreen mainScreen];
    if (!screen) return;
    CGFloat scale = screen.backingScaleFactor;
    CGDirectDisplayID screenNumber = (CGDirectDisplayID)[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];

    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO
        completionHandler:^(SCShareableContent *content, NSError *error) {
        if (error || !content) { dispatch_async(dispatch_get_main_queue(), ^{ [self showPermissionHelp]; }); return; }

        SCDisplay *display = nil;
        for (SCDisplay *d in content.displays) if (d.displayID == screenNumber) { display = d; break; }
        if (!display) display = content.displays.firstObject;
        if (!display) { dispatch_async(dispatch_get_main_queue(), ^{ [self showPermissionHelp]; }); return; }

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        config.width = (size_t)(screen.frame.size.width * scale);
        config.height = (size_t)(screen.frame.size.height * scale);
        config.showsCursor = NO;
        config.captureResolution = SCCaptureResolutionBest;

        [SCScreenshotManager captureImageWithFilter:filter configuration:config
            completionHandler:^(CGImageRef cg, NSError *err2) {
            if (err2 || !cg) { dispatch_async(dispatch_get_main_queue(), ^{ [self showPermissionHelp]; }); return; }
            CGImageRef retained = CGImageRetain(cg);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self presentCGImage:retained onScreen:screen scale:scale];
                CGImageRelease(retained);
            });
        }];
    }];
}

- (void)presentCGImage:(CGImageRef)cgImage onScreen:(NSScreen *)screen scale:(CGFloat)scale {
    OverlayWindow *win = [[OverlayWindow alloc] initWithContentRect:screen.frame
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    win.level = NSScreenSaverWindowLevel;
    win.backgroundColor = [NSColor clearColor];
    win.opaque = NO;
    win.ignoresMouseEvents = NO;
    win.acceptsMouseMovedEvents = YES;
    [win setFrame:screen.frame display:YES];

    OverlayView *view = [[OverlayView alloc] initWithFrame:CGRectMake(0, 0, screen.frame.size.width, screen.frame.size.height)];
    view.background = [[NSImage alloc] initWithCGImage:cgImage size:screen.frame.size];
    view.backingScale = scale;
    __weak CaptureController *weakSelf = self;
    view.onFinish = ^{
        [weakSelf.window orderOut:nil]; weakSelf.window = nil;
        [NSApp terminate:nil];   // редактор одноразовий: завершуємось після знімка
    };
    win.contentView = view;

    [NSApp activateIgnoringOtherApps:YES];
    [win makeKeyAndOrderFront:nil];
    [win makeFirstResponder:view];
    self.window = win;
}

- (void)showPermissionHelp {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Потрібен доступ «Запис екрана»";
    a.informativeText = @"Увімкни ShotShotCpp у Системні налаштування → Приватність і безпека → Запис екрана, потім перезапусти застосунок.";
    [a addButtonWithTitle:@"Відкрити налаштування"];
    [a addButtonWithTitle:@"Скасувати"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([a runModal] == NSAlertFirstButtonReturn) {
        NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"];
        if (url) [[NSWorkspace sharedWorkspace] openURL:url];
    }
    [NSApp terminate:nil];   // без доступу редактору нема що робити
}

@end

// MARK: - App (одноразовий редактор: запуск → знімок → анотації → вихід)
//
// Хоткей ⌘⇧7 тепер тримає окремий C++ демон (shotd.cpp, без AppKit), який
// запускає цей процес на вимогу. Тому тут немає ні хоткея, ні менюбар-іконки.

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end
@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [[CaptureController shared] begin];   // знімок одразу
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
