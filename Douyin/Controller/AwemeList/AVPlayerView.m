//
//  AVPlayerView.m
//  Douyin
//
//  Created by Qiao Shi on 2018/7/30.
//  Copyright © 2018年 Qiao Shi. All rights reserved.
//

#import "AVPlayerView.h"
#import "Constants.h"
#import "NetworkHelper.h"
#import "AVPlayerManager.h"

@interface AVPlayerView () <NSURLSessionTaskDelegate, NSURLSessionDataDelegate,  AVAssetResourceLoaderDelegate>
@property (nonatomic ,strong) NSURL                *sourceURL;        //视频路径
@property (nonatomic ,strong) AVURLAsset           *urlAsset;         //视频资源
@property (nonatomic ,strong) AVPlayerItem         *playerItem;       //视频资源载体
@property (nonatomic ,strong) AVPlayer             *player;           //视频播放器
@property (nonatomic ,strong) AVPlayerLayer        *playerLayer;      //视频播放器图形化载体
@property (nonatomic ,strong) id                   timeObserver;      //视频播放器周期性调用的观察者

@property (nonatomic, strong) NSMutableData        *data;             //视频缓冲数据

@property (nonatomic, strong) NSURLSession         *session;          //视频下载session
@property (nonatomic, strong) NSURLSessionDataTask *task;             //视频下载NSURLSessionDataTask

@property (nonatomic, strong) NSHTTPURLResponse    *response;         //视频下载请求响应
@property (nonatomic, strong) NSMutableArray       *pendingRequests;  //存储AVAssetResourceLoadingRequest的数组

@property (nonatomic, copy) NSString               *cacheFileKey;     //缓存文件key值
@property (nonatomic, strong) NSOperation          *queryCacheOperation;  //查找本地视频缓存数据的NSOperation
@end

@implementation AVPlayerView
//重写initWithFrame
-(instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if(self) {
        //初始化NSURLSession
        self.session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration] delegate:self delegateQueue:[NSOperationQueue mainQueue]];
        //初始化存储AVAssetResourceLoadingRequest的数组
        self.pendingRequests = [NSMutableArray array];
        
        //初始化视频播放器
        self.player = [AVPlayer new];
        //添加视频播放器图形化载体AVPlayerLayer
        self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
        self.playerLayer.backgroundColor = ColorClear.CGColor;
        [self.layer addSublayer:self.playerLayer];
        //给AVPlayerLayer添加周期性调用的观察者，用于更新视频播放进度
        [self addProgressObserver];
    }
    return self;
}

-(void)layoutSubviews {
    [super layoutSubviews];
    //禁止隐式动画
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _playerLayer.frame = self.layer.bounds;
    [CATransaction commit];
}

//设置播放路径
-(void)setPlayerWithUrl:(NSString *)url {
    //播放路径
    self.sourceURL = [NSURL URLWithString:url];
    //路径作为视频缓存key
    _cacheFileKey = self.sourceURL.absoluteString;
    
    __weak __typeof(self) wself = self;
    //查找本地视频缓存数据
    _queryCacheOperation = [[WebCache sharedWebCache] queryURLFromDiskMemory:_cacheFileKey cacheQueryCompletedBlock:^(id data, BOOL hasCache) {
        //hasCache是否有缓存，data为本地缓存路径
        if(!hasCache) {
            //当前路径无缓存，则将视频的网络路径的scheme改为其他自定义的scheme类型，http、https这类预留的scheme类型不能使AVAssetResourceLoaderDelegate中的方法回调
            wself.sourceURL = [wself.sourceURL.absoluteString urlScheme:@"streaming"];
        }else {
            //当前路径有缓存，则使用本地路径作为播放源
            wself.sourceURL = [NSURL fileURLWithPath:data];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            //初始化AVURLAsset
            wself.urlAsset = [AVURLAsset URLAssetWithURL:wself.sourceURL options:nil];
            //设置AVAssetResourceLoaderDelegate代理
            [wself.urlAsset.resourceLoader setDelegate:wself queue:dispatch_get_main_queue()];
            //初始化AVPlayerItem
            wself.playerItem = [AVPlayerItem playerItemWithAsset:wself.urlAsset];
            //观察playerItem.status属性
            [wself.playerItem addObserver:wself forKeyPath:@"status" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:NULL];
            //切换当前AVPlayer播放器的视频源
            [wself.player replaceCurrentItemWithPlayerItem:wself.playerItem];
        });
    } extension:@"mp4"];
}

//取消播放
-(void)cancelLoading {
    //隐藏playerLayer
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self.playerLayer setHidden:YES];
    [CATransaction commit];
    
    
    //取消查找本地视频缓存数据的NSOperation任务
    [_queryCacheOperation cancel];
    //暂停视频播放
    [self pause];
    //取消AVURLAsset加载，这一步很重要，及时取消到AVAssetResourceLoaderDelegate视频源的加载，避免AVPlayer视频源切换时发生的错位现象
    [self.urlAsset cancelLoading];
    //取消网络下载请求
    [self.task cancel];
    self.task = nil;
    self.data = nil;
    self.response = nil;
    
    //结束所有视频数据加载请求
    for(AVAssetResourceLoadingRequest *loadingRequest in self.pendingRequests) {
        if(![loadingRequest isFinished]) {
            [loadingRequest finishLoading];
        }
    }
    [self.pendingRequests removeAllObjects];
    
}

//更新AVPlayer状态，当前播放则暂停，当前暂停则播放
-(void)updatePlayerState {
    if(_player.rate == 0) {
        [self play];
    }else {
        [self pause];
    }
}

//移除KVO
- (void)removeObserver {
    @try {
        [self.playerItem removeObserver:self forKeyPath:@"status"];
        [self.player removeObserver:self forKeyPath:@"rate"];
        [self.player removeTimeObserver:self.timeObserver];
    } @catch (NSException *exception) {
        NSLog(@"%@", exception.description);
    }
}

//播放
-(void)play {
    [[AVPlayerManager shareManager] play:_player];
}

//暂停
-(void)pause {
    [[AVPlayerManager shareManager] pause:_player];
}

//重新播放
-(void)replay {
    [[AVPlayerManager shareManager] replay:_player];
}

//播放速度
-(CGFloat)rate {
    return [_player rate];
}

//NSURLSessionDataDelegate
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    //继续加载网络数据
    completionHandler(NSURLSessionResponseAllow);
    //初始化缓存数据
    self.data = [NSMutableData data];
    //初始化网络请求响应体
    self.response = (NSHTTPURLResponse *)response;
    //处理视频数据加载请求
    [self processPendingRequests];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    //填充下载的部分缓存数据
    [self.data appendData:data];
    //处理视频数据加载请求
    [self processPendingRequests];
}

//NSURLSessionTaskDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if(!error) {
        //下载完毕，将缓存数据保存到本地
        [[WebCache sharedWebCache] storeDataToDiskCache:_data key:_cacheFileKey extension:@"mp4"];
    }else {
        NSLog(@"%@", error.description);
    }
}

-(void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask willCacheResponse:(NSCachedURLResponse *)proposedResponse completionHandler:(void (^)(NSCachedURLResponse * _Nullable))completionHandler {
    NSCachedURLResponse *cachedResponse = proposedResponse;
    if (dataTask.currentRequest.cachePolicy == NSURLRequestReloadIgnoringLocalCacheData
        || [dataTask.currentRequest.URL.absoluteString isEqualToString:self.task.currentRequest.URL.absoluteString]) {
        cachedResponse = nil;
    }
    if (completionHandler) {
        completionHandler(cachedResponse);
    }
}

//AVAssetResourceLoaderDelegate
- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    //创建用于下载视频源的NSURLSessionDataTask，当前方法会多次调用，所以需判断self.task == nil
    if(self.task == nil) {
        //将当前的请求路径的scheme换成https，进行普通的网球请求
        NSURL *URL = [[loadingRequest.request URL].absoluteString urlScheme:@"https"];
        NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60];
        self.task = [self.session dataTaskWithRequest:request];
        [self.task resume];
    }
    //将视频加载请求依此存储到pendingRequests中，因为当前方法会多次调用，所以需用数组缓存
    [self.pendingRequests addObject:loadingRequest];
    return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    //AVAssetResourceLoadingRequest请求被取消，移除视频加载请求
    [self.pendingRequests removeObject:loadingRequest];
}
//AVURLAsset resource loading
- (void)processPendingRequests {
    NSMutableArray *requestsCompleted = [NSMutableArray array];
    //获取所有已完成AVAssetResourceLoadingRequest
    for (AVAssetResourceLoadingRequest *loadingRequest in self.pendingRequests) {
        //判断AVAssetResourceLoadingRequest是否完成
        BOOL didRespondCompletely = [self respondWithDataForRequest:loadingRequest];
        //结束AVAssetResourceLoadingRequest
        if (didRespondCompletely){
            [requestsCompleted addObject:loadingRequest];
            [loadingRequest finishLoading];
        }
    }
    //移除所有已完成AVAssetResourceLoadingRequest
    [self.pendingRequests removeObjectsInArray:requestsCompleted];
}

- (BOOL)respondWithDataForRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    //设置AVAssetResourceLoadingRequest的类型、支持断点下载、内容大小
    NSString *mimeType = [self.response MIMEType];
    CFStringRef contentType = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, (__bridge CFStringRef)(mimeType), NULL);
    loadingRequest.contentInformationRequest.byteRangeAccessSupported = YES;
    loadingRequest.contentInformationRequest.contentType = CFBridgingRelease(contentType);
    loadingRequest.contentInformationRequest.contentLength = [self.response expectedContentLength];
    
    //AVAssetResourceLoadingRequest请求偏移量
    long long startOffset = loadingRequest.dataRequest.requestedOffset;
    if (loadingRequest.dataRequest.currentOffset != 0) {
        startOffset = loadingRequest.dataRequest.currentOffset;
    }
    //判断当前缓存数据量是否大于请求偏移量
    if (self.data.length < startOffset) {
        return NO;
    }
    //计算还未装载到缓存数据
    NSUInteger unreadBytes = self.data.length - (NSUInteger)startOffset;
    //判断当前请求到的数据大小
    NSUInteger numberOfBytesToRespondWidth = MIN((NSUInteger)loadingRequest.dataRequest.requestedLength, unreadBytes);
    //将缓存数据的指定片段装载到视频加载请求中
    [loadingRequest.dataRequest respondWithData:[self.data subdataWithRange:NSMakeRange((NSUInteger)startOffset, numberOfBytesToRespondWidth)]];
    //计算装载完毕后的数据偏移量
    long long endOffset = startOffset + loadingRequest.dataRequest.requestedLength;
    //判断请求是否完成
    BOOL didRespondFully = self.data.length >= endOffset;
    
    return didRespondFully;
}

//给AVPlayerLayer添加周期性调用的观察者，用于更新视频播放进度
-(void)addProgressObserver{
    __weak __typeof(self) weakSelf = self;
    //AVPlayer添加周期性回调观察者，一秒调用一次block，用于更新视频播放进度
    _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMake(1, 1) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
        //获取当前播放时间
        float current = CMTimeGetSeconds(time);
        //获取视频播放总时间
        float total = CMTimeGetSeconds([weakSelf.playerItem duration]);
        //重新播放视频
        if(total == current) {
            [weakSelf replay];
        }
        //更新视频播放进度方法回调
        if(weakSelf.delegate) {
            [weakSelf.delegate onProgressUpdate:current total:total];
        }
    }];
}

//响应KVO值变化的方法
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    //AVPlayerItem.status
    if([keyPath isEqualToString:@"status"]) {
        //视频源装备完毕，则显示playerLayer
        if(_playerItem.status == AVPlayerItemStatusReadyToPlay) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [self.playerLayer setHidden:NO];
            [CATransaction commit];
            self.playerLayer.backgroundColor = ColorBlack.CGColor;
        }
        //视频播放状体更新方法回调
        if(self.delegate) {
            [self.delegate onPlayItemStatusUpdate:_playerItem.status];
        }
    }else {
        return [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}
@end
