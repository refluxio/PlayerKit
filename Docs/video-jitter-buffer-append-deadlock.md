# VideoJitterBuffer.append 自死锁（未提交的 120fps 修复引入）

## 背景

这不是已提交代码里的 bug，是**这台机器上还没 commit 的本地改动**：`Sources/PlayerKitNative/VideoJitterBuffer.swift`
和它的测试文件相对于 `main`（`0b6c96a`）有未提交 diff——正是修"流浪地球卡死"（2026-09-22，4K HDR 120fps HEVC，
60 秒内状态只推进一次）那次的工作。这份记录只针对这次未提交的改动，`main` 上现在的已提交版本没有这个问题。

## 复现

不需要 4K/120fps 素材，也不需要真机——任何视频、任何调用方都会触发，这不是内容相关的 bug。三种独立方式都
100% 复现：

1. **最快**：`xcrun swift test --filter VideoJitterBufferTests`（注意用 `xcrun swift`，不要直接用
   `swift`——这台机器 `/opt/homebrew/bin/swift` 被 pip 装的 OpenStack `python-swiftclient` 占了名字，
   直接跑 `swift test` 会先炸在无关的 Python 报错上，跟这个 bug 无关，是环境问题）。测试卡住不返回；
   `sample` 一下挂起的 `xctest` 进程，栈是：
   `testConfiguredFrameRateReachesResumeDurationAt120fps()`（`VideoJitterBufferTests.swift:144`）→
   `VideoJitterBuffer.append(_:)`（`VideoJitterBuffer.swift:105`）→
   `VideoJitterBuffer.maxFrameCount.getter`（`VideoJitterBuffer.swift:43`）→ `_pthread_mutex_firstfit_lock_wait`。
   **改动自带的测试从写下来就没有真正跑通过。**
2. 起一个真实的 LatticeCast 接收端（reflux 的 macOS app，`LatticeCastRendererBridge` 接到 reflux 自己的
   `PlayerController`），投两条完全无关的自造测试片（一条 300 秒 testsrc+sine，一条 15 秒
   baseline profile 无 B 帧的简化版）过去。两次都是**第一帧就死锁**：CPU 掉到 ~0%，没有播放器窗口，
   `cast_status` 请求直接超时。
3. 用 `sample` 在两次独立的进程/播放会话上各抓了一次线程栈（方式 2），相隔十几秒，卡的位置逐字节相同：
   - 主线程：`DisplayLinkProxy.tick()` → `NativeBackend.displayNextFrame()` →
     `VideoJitterBuffer.state.getter`（`VideoJitterBuffer.swift:74`）→ 卡在 `_pthread_mutex_firstfit_lock_wait`
   - demux 线程：`NativeBackend.startDemuxLoop()` → `VideoJitterBuffer.append(_:)` →
     `VideoJitterBuffer.maxFrameCount.getter` → 同样卡在 `_pthread_mutex_firstfit_lock_wait`

## 根因

`append(_:)`（demux 线程写入）持锁后，中途去读 `self.maxFrameCount`——一个同样会自己上锁的计算属性：

```swift
func append(_ frame: Frame) {
    lock.lock()
    ...
    if frames.count > maxFrameCount { frames.removeFirst() }   // ← 触发下面这个 getter
    ...
    lock.unlock()
}

var maxFrameCount: Int {
    lock.lock(); defer { lock.unlock() }   // ← 同一把 NSLock，同一线程，append() 还没解锁
    return max(60, Int((framesPerSecondHint * maxDuration).rounded(.up)))
}
```

`lock` 是 `NSLock`，**不可重入**。同一线程对同一把非重入锁二次加锁必然永久阻塞——这是无条件触发的，
不是竞态。`if frames.count > maxFrameCount` 里 `>` 两边都要求值，`maxFrameCount` 这个 getter 在
`append()` 每次调用时都会被执行，从第一帧开始就会自锁。`state`（主线程/显示线程读）和
`duration`（同文件另一处只读属性）也各自独立 `lock.lock()`，一旦 `append()` 把自己锁死并且永不释放，
其它所有想拿这把锁的线程也跟着永久卡住——这就是我看到的"两条线程各卡一处"的现象。

`configureFrameRate(_:)`（同一文件，同样改动引入）没有这个问题：它不在持锁状态下调用其它会加锁的成员。

## 和"流浪地球"那个 bug 的关系

不是同一个问题，是修那个问题时带出来的新问题：

- **旧 bug**（已知，`main` 上现在的版本仍未修）：`maxFrameCount` 写死 60，120fps 内容只等于 0.5 秒缓冲，
  低于开播门槛也低于防抖门槛，形成"开播→弹一帧→冻结 4 秒"的循环——这是**卡顿**，不是死锁，进程本身没有
  被锁住，只是画面推进极慢。
- **这次发现的死锁**：与内容无关，我用两条完全不是 4K/120fps 的普通测试片就 100% 复现，根因是纯逻辑
  上的重入锁问题，与"帧率算得对不对"无关，是把 `maxFrameCount` 从存量值改成计算属性时顺带引入的。

## 影响面

`append()` / `maxFrameCount` 是 demux 线程的通用代码，不区分调用方是投屏（LatticeCast）还是 reflux
自己平时打开一个本地文件。我没能在本次会话里用"reflux 打开本地文件"这条路径独立复现（遇到的是文件访问
本身没有触发起播，疑似沙盒对任意路径没有读权限，这个我没有深挖，是另一个待办，不代表那条路径没问题）。
但从代码逻辑看，`append()` 里这次比较是无条件执行的，没有理由只在投屏场景触发——**大概率是这份改动一旦
合并，会影响所有视频播放**，不止投屏。

## 建议的修法方向（未实施，留给实际改这段代码的人判断）

`append()` 已经持有 `lock`，判断上限时不应该再调用会加锁的 `maxFrameCount` getter，而是在已持锁的临界区里
直接用 `framesPerSecondHint`/`maxDuration` 内联算出同样的值（或者拆一个不加锁的私有版本给 `append()` 内部用，
公开的 `maxFrameCount` 保留加锁版本给外部调用方）。改完之后至少要把这份改动自带的、目前会挂住的单元测试
（尤其 `testConfiguredFrameRateReachesResumeDurationAt120fps`、`testConfiguredFrameRateSurvivesOnePopWithoutImmediatelyRebuffering`）
真正跑到通过，而不是写完没跑。

## 复现环境

2026-09-27，本地未提交改动（相对 `main` `0b6c96a`），macOS。真实 LatticeCast 接收端 + 真实 reflux
`PlayerController`，非 mock。原始线程栈样本、CPU/窗口观察记录在本次会话记录中，未附加到本文件。
