//
//  CustomAudioDevice.swift
//  4.Custom-Audio-Driver
//
//  Created by Roberto Perez Cubero on 21/09/2016.
//  Copyright © 2016 tokbox. All rights reserved.
//

import Foundation
import OpenTok

class CustomAudioDevice: NSObject, AudioTimeStampDelegate {
#if targetEnvironment(simulator)
    static let kSampleRate: UInt16 = 44100
#else
    static let kSampleRate: UInt16 = 48000
#endif
    static let kOutputBus = AudioUnitElement(0)
    static let kInputBus = AudioUnitElement(1)
    static let kAudioDeviceHeadset = "AudioSessionManagerDevice_Headset"
    static let kAudioDeviceBluetooth = "AudioSessionManagerDevice_Bluetooth"
    static let kAudioDeviceSpeaker = "AudioSessionManagerDevice_Speaker"
    static let kToMicroSecond: Double = 1000000
    static let kMaxPlayoutDelay: UInt8 = 150
    static let kMaxSampleBuffer = 8192*2
    
    var audioFormat = OTAudioFormat()
    let safetyQueue = DispatchQueue(label: "ot-audio-driver")

    var deviceAudioBus: OTAudioBus?
    
    func setAudioBus(_ audioBus: OTAudioBus?) -> Bool {
        deviceAudioBus = audioBus
        audioFormat = OTAudioFormat()
        audioFormat.sampleRate = CustomAudioDevice.kSampleRate
        audioFormat.numChannels = 1
        return true
    }
    
    var bufferList: UnsafeMutablePointer<AudioBufferList>?
    var bufferSize: UInt32 = 0
    var bufferNumFrames: UInt32 = 0
    var playoutAudioUnitPropertyLatency: Float64 = 0
    var playoutDelayMeasurementCounter: UInt32 = 0
    var recordingDelayMeasurementCounter: UInt32 = 0
    var recordingDelay: UInt32 = 0
    var recordingAudioUnitPropertyLatency: Float64 = 0
    var playoutDelay: UInt32 = 0
    var playing = false
    var playoutInitialized = false
    var recording = false
    var recordingInitialized = false
    var interruptedPlayback = false
    var isRecorderInterrupted = false
    var isPlayerInterrupted = false
    var isResetting = false
    var restartRetryCount = 0
    fileprivate var recordingVoiceUnit: AudioUnit?
    fileprivate var playoutVoiceUnit: AudioUnit?
    fileprivate var fileAudioBuffer = [Int16]()
    fileprivate var isFileAudioLocked = false
    
    fileprivate var previousAVAudioSessionCategory: AVAudioSession.Category?
    fileprivate var avAudioSessionMode: AVAudioSession.Mode?
    fileprivate var avAudioSessionPreffSampleRate = Double(0)
    fileprivate var avAudioSessionChannels = 0
    fileprivate var isAudioSessionSetup = false
    
    var areListenerBlocksSetup = false
    var streamFormat = AudioStreamBasicDescription()
    
    fileprivate var videoInput: AVAsset
    var videoPlayer: VideoCapturer
    var lastTimeStamp: CMTime = CMTime()
    let audioCaptureQueue = DispatchQueue(label: "file-audio-driver")
    
    deinit {
        tearDownAudio()
        removeObservers()
    }
    
    init(video: AVAsset, videoCapturer: VideoCapturer) {
        videoInput = video
        videoPlayer = videoCapturer
        super.init()
        videoPlayer.audioDelegate = self
        audioFormat.sampleRate = CustomAudioDevice.kSampleRate
        audioFormat.numChannels = 1
    }
    
    func valueChanged() -> CMTime {
        return lastTimeStamp
    }
    
    fileprivate func restartAudio() {
        safetyQueue.async {
            self.doRestartAudio(numberOfAttempts: 3)
        }
    }
    
    fileprivate func restartAudioAfterInterruption() {
        if isRecorderInterrupted {
            if startCapture() {
                isRecorderInterrupted = false
                restartRetryCount = 0
            } else {
                restartRetryCount += 1
                if restartRetryCount < 3 {
                    safetyQueue.asyncAfter(deadline: DispatchTime.now(), execute: { [unowned self] in
                        self.restartAudioAfterInterruption()
                    })
                } else {
                    isRecorderInterrupted = false
                    isPlayerInterrupted = false
                    restartRetryCount = 0
                    print("ERROR[OpenTok]:Unable to acquire audio session")
                }
            }
        }
        if isPlayerInterrupted {
            isPlayerInterrupted = false
            let _ = startRendering()
        }
    }
    
    fileprivate func doRestartAudio(numberOfAttempts: Int) {
        isResetting = true
        
        if recording {
            let _ = stopCapture()
            disposeAudioUnit(audioUnit: &recordingVoiceUnit)
            let _ = startCapture()
        }
        
        if playing {
            let _ = self.stopRendering()
            disposeAudioUnit(audioUnit: &playoutVoiceUnit)
            let _ = self.startRendering()
        }
        isResetting = false
    }
    
    fileprivate func setupAudioUnit(withPlayout playout: Bool) -> Bool {
        if !isAudioSessionSetup {
            setupAudioSession()
            isAudioSessionSetup = true
        }
        
        let bytesPerSample = UInt32(MemoryLayout<Int16>.size)
        streamFormat.mFormatID = kAudioFormatLinearPCM
        streamFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        streamFormat.mBytesPerPacket = bytesPerSample
        streamFormat.mFramesPerPacket = 1
        streamFormat.mBytesPerFrame = bytesPerSample
        streamFormat.mChannelsPerFrame = 1
        streamFormat.mBitsPerChannel = 8 * bytesPerSample
        streamFormat.mSampleRate = Float64(CustomAudioDevice.kSampleRate)
        
        var audioUnitDescription = AudioComponentDescription()
        audioUnitDescription.componentType = kAudioUnitType_Output
        audioUnitDescription.componentSubType = kAudioUnitSubType_VoiceProcessingIO
        audioUnitDescription.componentManufacturer = kAudioUnitManufacturer_Apple
        audioUnitDescription.componentFlags = 0
        audioUnitDescription.componentFlagsMask = 0
        
        let foundVpioUnitRef = AudioComponentFindNext(nil, &audioUnitDescription)
        let result: OSStatus = {
            if playout {
                return AudioComponentInstanceNew(foundVpioUnitRef!, &playoutVoiceUnit)
            } else {
                return AudioComponentInstanceNew(foundVpioUnitRef!, &recordingVoiceUnit)
            }
        }()
        
        if result != noErr {
            print("Error seting up audio unit")
            return false
        }
        
        var value: UInt32 = 1
        if playout {
            AudioUnitSetProperty(playoutVoiceUnit!, kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Output, CustomAudioDevice.kOutputBus, &value,
                                 UInt32(MemoryLayout<UInt32>.size))
            
            AudioUnitSetProperty(playoutVoiceUnit!, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input, CustomAudioDevice.kOutputBus, &streamFormat,
                                 UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            // Disable Input on playout
            var enableInput = 0
            AudioUnitSetProperty(playoutVoiceUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                                 CustomAudioDevice.kInputBus, &enableInput, UInt32(MemoryLayout<UInt32>.size))
        } else {
            AudioUnitSetProperty(recordingVoiceUnit!, kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Input, CustomAudioDevice.kInputBus, &value,
                                 UInt32(MemoryLayout<UInt32>.size))
            AudioUnitSetProperty(recordingVoiceUnit!, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output, CustomAudioDevice.kInputBus, &streamFormat,
                                 UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
            // Disable Output on record
            var enableOutput = 0
            AudioUnitSetProperty(recordingVoiceUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                                 CustomAudioDevice.kOutputBus, &enableOutput, UInt32(MemoryLayout<UInt32>.size))
        }
        
        if playout {
            setupPlayoutCallback()
        } else {
            setupRecordingCallback()
        }
        
        setBluetoothAsPreferredInputDevice()
        
        return true
    }
    
    fileprivate func setupPlayoutCallback() {
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        var renderCallback = AURenderCallbackStruct(inputProc: renderCb, inputProcRefCon: selfPointer)
        AudioUnitSetProperty(playoutVoiceUnit!,
                             kAudioUnitProperty_SetRenderCallback,
                             kAudioUnitScope_Input,
                             CustomAudioDevice.kOutputBus,
                             &renderCallback,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        
    }
    
    fileprivate func setupRecordingCallback() {
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        var inputCallback = AURenderCallbackStruct(inputProc: recordCb, inputProcRefCon: selfPointer)
        AudioUnitSetProperty(recordingVoiceUnit!,
                             kAudioOutputUnitProperty_SetInputCallback,
                             kAudioUnitScope_Global,
                             CustomAudioDevice.kInputBus,
                             &inputCallback,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        
        var value = 0
        AudioUnitSetProperty(recordingVoiceUnit!,
                             kAudioUnitProperty_ShouldAllocateBuffer,
                             kAudioUnitScope_Output,
                             CustomAudioDevice.kInputBus,
                             &value,
                             UInt32(MemoryLayout<UInt32>.size))
    }
    
    fileprivate func disposeAudioUnit(audioUnit: inout AudioUnit?) {
        if let unit = audioUnit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        audioUnit = nil
    }
    
    fileprivate func tearDownAudio() {
        print("Destoying audio units")
        disposeAudioUnit(audioUnit: &playoutVoiceUnit)
        disposeAudioUnit(audioUnit: &recordingVoiceUnit)
        freeupAudioBuffers()
        
        let session = AVAudioSession.sharedInstance()
        do {
            guard let previousAVAudioSessionCategory = previousAVAudioSessionCategory else { return }
            try session.setCategory(previousAVAudioSessionCategory, mode: .default)
            guard let avAudioSessionMode = avAudioSessionMode else { return }
            try session.setMode(avAudioSessionMode)
            try session.setPreferredSampleRate(avAudioSessionPreffSampleRate)
            try session.setPreferredInputNumberOfChannels(avAudioSessionChannels)
            
            isAudioSessionSetup = false
        } catch {
            print("Error reseting AVAudioSession")
        }
    }
    
    fileprivate func freeupAudioBuffers() {
        if var data = bufferList?.pointee, data.mBuffers.mData != nil {
            data.mBuffers.mData?.assumingMemoryBound(to: UInt16.self).deallocate()
            data.mBuffers.mData = nil
        }
        
        if let list = bufferList {
            list.deallocate()
        }
        
        bufferList = nil
        bufferNumFrames = 0
    }
    
    fileprivate func playAudio() {
        do{
            let assetReader = try AVAssetReader(asset: videoInput)

            let track = videoInput.tracks(withMediaType: AVMediaType.audio).first

            let audioSettings:NSDictionary = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: CustomAudioDevice.kSampleRate,
                AVNumberOfChannelsKey:1,
                AVLinearPCMIsBigEndianKey: 0,
                AVLinearPCMIsFloatKey: 0,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsNonInterleaved: 0
            ]

            let trackOutput = AVAssetReaderTrackOutput(track: track!, outputSettings: audioSettings as! [String : Int])
              assetReader.add(trackOutput)
              assetReader.startReading()
            // var sampleData = NSMutableData()

              while assetReader.status == AVAssetReader.Status.reading {
                if let sampleBufferRef = trackOutput.copyNextSampleBuffer() {
                  if let blockBufferRef = CMSampleBufferGetDataBuffer(sampleBufferRef) {

                    var timingInfo = CMSampleTimingInfo.invalid
                    CMSampleBufferGetSampleTimingInfo(sampleBufferRef,at: 0, timingInfoOut: &timingInfo)
                    let oldTS = lastTimeStamp
                    let currentTS = timingInfo.presentationTimeStamp

                    let previousTime = Double(oldTS.value) / Double(oldTS.timescale)
                    let currentTime = Double(currentTS.value) / Double(currentTS.timescale)

                    lastTimeStamp = timingInfo.presentationTimeStamp
                    videoPlayer.setAudioTimeStamp()

                    let bufferLength = CMBlockBufferGetDataLength(blockBufferRef)
                    let data:[Int32] = Array(repeating: 0, count: bufferLength)
                    let samples = UnsafeMutableRawPointer(mutating: data)

                    CMBlockBufferCopyDataBytes(blockBufferRef, atOffset: 0, dataLength: bufferLength, destination: samples)

//                  sampleData.append(samples, length: bufferLength)

                    let numberOfSamples = CMSampleBufferGetNumSamples(sampleBufferRef)

//                  deviceAudioBus!.writeCaptureData(samples, numberOfSamples: UInt32(numberOfSamples))
                    CMSampleBufferInvalidate(sampleBufferRef)

                      while (isFileAudioLocked || fileAudioBuffer.count > CustomAudioDevice.kMaxSampleBuffer) {}

                      isFileAudioLocked = true
                      fileAudioBuffer = fileAudioBuffer + samples.toArray(to: Int16.self, capacity: numberOfSamples)
                      isFileAudioLocked = false

                      Thread.sleep(forTimeInterval: currentTime - previousTime - 0.005) // read slightly faster
                  }
                }
              }
          }catch{
              fatalError("Unable to read Asset: \(error) : \(#function).")
          }
    }
}

extension UnsafeMutableRawPointer {
    func toArray<T>(to type: T.Type, capacity count: Int) -> [T] {
        return Array(UnsafeBufferPointer(start: bindMemory(to: type, capacity: count), count: count))
    }
}

// MARK: - Audio Device Implementation
extension CustomAudioDevice: OTAudioDevice {
    func  captureFormat() ->  OTAudioFormat {
        return audioFormat
    }
    func renderFormat() -> OTAudioFormat {
        return audioFormat
    }
    func renderingIsAvailable() -> Bool {
        return true
    }
    func renderingIsInitialized() -> Bool {
        return playoutInitialized
    }
    func isRendering() -> Bool {
        return playing
    }
    func isCapturing() -> Bool {
        return recording
    }
    func estimatedRenderDelay() -> UInt16 {
        return UInt16(min(self.playoutDelay, UInt32(CustomAudioDevice.kMaxPlayoutDelay)))
    }
    func estimatedCaptureDelay() -> UInt16 {
        return UInt16(self.recordingDelay)
    }
    func captureIsAvailable() -> Bool {
        return true
    }
    func captureIsInitialized() -> Bool {
        return recordingInitialized
    }
    
    func initializeRendering() -> Bool {
        if playing { return false }
        
        playoutInitialized = true
        return playoutInitialized
    }
    
    func startRendering() -> Bool {
        if playing { return true }
        playing = true
        if playoutVoiceUnit == nil {
            playing = setupAudioUnit(withPlayout: true)
            if !playing {
                return false
            }
        }
        
        let result = AudioOutputUnitStart(playoutVoiceUnit!)
        
        if result != noErr {
            print("Error creaing rendering unit")
            playing = false
        }
        return playing
    }
    
    func stopRendering() -> Bool {
        if !playing {
            return true
        }
        
        playing = false
        
        if (playoutVoiceUnit != nil) {
            let result = AudioOutputUnitStop(playoutVoiceUnit!)
            if result != noErr {
                return false
            }
        }
        
        if !recording && !isPlayerInterrupted && !isResetting {
            tearDownAudio()
        }
        
        return true
    }
    
    
    func initializeCapture() -> Bool {
        if recording { return false }
        
        recordingInitialized = true
        return recordingInitialized
    }
    
    func startCapture() -> Bool {
        if recording {
            return true
        }
        
        recording = true

        audioCaptureQueue.async {
            while(self.recording) {
                self.playAudio()
            }
        }
        if recordingVoiceUnit == nil {
            recording = setupAudioUnit(withPlayout: false)

            if !recording {
                return false
            }
        }

        let result = AudioOutputUnitStart(recordingVoiceUnit!)
        if result != noErr {
            recording = false
        }
        
        return recording
    }
    
    func stopCapture() -> Bool {
        if !recording {
            return true
        }
        
        recording = false
        
        if (recordingVoiceUnit != nil) {
            let result = AudioOutputUnitStop(recordingVoiceUnit!)
            
            if result != noErr {
                return false
            }
        }
        
        freeupAudioBuffers()
        
        if !recording && !isRecorderInterrupted && !isResetting {
            tearDownAudio()
        }
        
        return true
    }
    
}

// MARK: - AVAudioSession
extension CustomAudioDevice {
    @objc func onInterruptionEvent(notification: Notification) {
        let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
        safetyQueue.async {
            self.handleInterruptionEvent(type: type as? Int)
        }
    }
    
    fileprivate func handleInterruptionEvent(type: Int?) {
        guard let interruptionType = type else {
            return
        }
        
        switch  UInt(interruptionType) {
        case AVAudioSession.InterruptionType.began.rawValue:
            if recording {
                isRecorderInterrupted = true
                let _ = stopCapture()
            }
            if playing {
                isPlayerInterrupted = true
                let _ = stopRendering()
            }
        case AVAudioSession.InterruptionType.ended.rawValue:
            configureAudioSessionWithDesiredAudioRoute(desiredAudioRoute: CustomAudioDevice.kAudioDeviceBluetooth)
            restartAudioAfterInterruption()
        default:
            break
        }
    }
    
    @objc func onRouteChangeEvent(notification: Notification) {
        safetyQueue.async {
            self.handleRouteChangeEvent(notification: notification)
        }
    }
    
    @objc func appDidBecomeActive(notification: Notification) {
        safetyQueue.async {
            self.handleInterruptionEvent(type: Int(AVAudioSession.InterruptionType.ended.rawValue))
        }
    }
    
    fileprivate func handleRouteChangeEvent(notification: Notification) {
        guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else {
            return
        }
        
        if reason == AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue {
            return
        }
        
        if reason == AVAudioSession.RouteChangeReason.override.rawValue ||
            reason == AVAudioSession.RouteChangeReason.categoryChange.rawValue {
            
            let oldRouteDesc = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as! AVAudioSessionRouteDescription
            let outputs = oldRouteDesc.outputs
            var oldOutputDeviceName: String? = nil
            var currentOutputDeviceName: String? = nil
            
            if outputs.count > 0 {
                let portDesc = outputs[0]
                oldOutputDeviceName = portDesc.portName
            }
            
            if AVAudioSession.sharedInstance().currentRoute.outputs.count > 0 {
                currentOutputDeviceName = AVAudioSession.sharedInstance().currentRoute.outputs[0].portName
            }
            
            if oldOutputDeviceName == currentOutputDeviceName || currentOutputDeviceName == nil || oldOutputDeviceName == nil {
                return
            }
            
            restartAudio()
        }
    }
    
    fileprivate func setupListenerBlocks() {
        if areListenerBlocksSetup {
            return
        }
        
        let notificationCenter = NotificationCenter.default
        
        notificationCenter.addObserver(self, selector: #selector(CustomAudioDevice.onInterruptionEvent),
                                       name: AVAudioSession.interruptionNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(CustomAudioDevice.onRouteChangeEvent(notification:)),
                                       name: AVAudioSession.routeChangeNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(CustomAudioDevice.appDidBecomeActive(notification:)),
                                       name: UIApplication.didBecomeActiveNotification, object: nil)
        
        areListenerBlocksSetup = true
    }
    
    fileprivate func removeObservers() {
        NotificationCenter.default.removeObserver(self)
        areListenerBlocksSetup = false
    }
    
    fileprivate func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        
        previousAVAudioSessionCategory = session.category
        avAudioSessionMode = session.mode
        avAudioSessionPreffSampleRate = session.preferredSampleRate
        avAudioSessionChannels = session.inputNumberOfChannels
        do {
            try session.setPreferredSampleRate(Double(CustomAudioDevice.kSampleRate))
            try session.setPreferredIOBufferDuration(0.01)
            let audioOptions = AVAudioSession.CategoryOptions.mixWithOthers.rawValue |
                AVAudioSession.CategoryOptions.allowBluetooth.rawValue |
                AVAudioSession.CategoryOptions.defaultToSpeaker.rawValue
            try session.setCategory(AVAudioSession.Category.playAndRecord, mode: AVAudioSession.Mode.videoChat, options: AVAudioSession.CategoryOptions(rawValue: audioOptions))
            setupListenerBlocks()
            
            try session.setActive(true)
        } catch let err as NSError {
            print("Error setting up audio session \(err)")
        } catch {
            print("Error setting up audio session")
        }
    }
}

// MARK: - Audio Route functions
extension CustomAudioDevice {
    fileprivate func setBluetoothAsPreferredInputDevice() {
        let btRoutes = [AVAudioSession.Port.bluetoothA2DP, AVAudioSession.Port.bluetoothLE, AVAudioSession.Port.bluetoothHFP]
        AVAudioSession.sharedInstance().availableInputs?.forEach({ el in
            if btRoutes.contains(el.portType) {
                do {
                    try AVAudioSession.sharedInstance().setPreferredInput(el)
                } catch {
                    print("Error setting BT as preferred input device")
                }
            }
        })
    }
    
    fileprivate func configureAudioSessionWithDesiredAudioRoute(desiredAudioRoute: String) {
        let session = AVAudioSession.sharedInstance()
        
        if desiredAudioRoute == CustomAudioDevice.kAudioDeviceBluetooth {
            setBluetoothAsPreferredInputDevice()
        }
        do {
            if desiredAudioRoute == CustomAudioDevice.kAudioDeviceSpeaker {
                try session.overrideOutputAudioPort(AVAudioSession.PortOverride.speaker)
            } else {
                try session.overrideOutputAudioPort(AVAudioSession.PortOverride.none)
            }
        } catch let err as NSError {
            print("Error setting audio route: \(err)")
        }
    }
}

// MARK: - Render and Record C Callbacks
func renderCb(inRefCon:UnsafeMutableRawPointer,
              ioActionFlags:UnsafeMutablePointer<AudioUnitRenderActionFlags>,
              inTimeStamp:UnsafePointer<AudioTimeStamp>,
              inBusNumber:UInt32,
              inNumberFrames:UInt32,
              ioData:UnsafeMutablePointer<AudioBufferList>?) -> OSStatus
{
    let audioDevice: CustomAudioDevice = Unmanaged.fromOpaque(inRefCon).takeUnretainedValue()
    if !audioDevice.playing { return 0 }
    
    let _ = audioDevice.deviceAudioBus!.readRenderData((ioData?.pointee.mBuffers.mData)!, numberOfSamples: inNumberFrames)
    updatePlayoutDelay(withAudioDevice: audioDevice)
    
    return noErr
}

func recordCb(inRefCon:UnsafeMutableRawPointer,
              ioActionFlags:UnsafeMutablePointer<AudioUnitRenderActionFlags>,
              inTimeStamp:UnsafePointer<AudioTimeStamp>,
              inBusNumber:UInt32,
              inNumberFrames:UInt32,
              ioData:UnsafeMutablePointer<AudioBufferList>?) -> OSStatus
{
    let audioDevice: CustomAudioDevice = Unmanaged.fromOpaque(inRefCon).takeUnretainedValue()
    if audioDevice.bufferList == nil || inNumberFrames > audioDevice.bufferNumFrames {
        if audioDevice.bufferList != nil {
            audioDevice.bufferList!.pointee.mBuffers.mData?
                .assumingMemoryBound(to: UInt16.self).deallocate()
            audioDevice.bufferList?.deallocate()
        }
        
        audioDevice.bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        audioDevice.bufferList?.pointee.mNumberBuffers = 1
        audioDevice.bufferList?.pointee.mBuffers.mNumberChannels = 1
        
        audioDevice.bufferList?.pointee.mBuffers.mDataByteSize = inNumberFrames * UInt32(MemoryLayout<UInt16>.size)
        audioDevice.bufferList?.pointee.mBuffers.mData = UnsafeMutableRawPointer(UnsafeMutablePointer<UInt16>.allocate(capacity: Int(inNumberFrames)))
        audioDevice.bufferNumFrames = inNumberFrames
        audioDevice.bufferSize = (audioDevice.bufferList?.pointee.mBuffers.mDataByteSize)!
    }
    
    AudioUnitRender(audioDevice.recordingVoiceUnit!,
                    ioActionFlags,
                    inTimeStamp,
                    1,
                    inNumberFrames,
                    audioDevice.bufferList!)
    
    if audioDevice.recording {
        if (audioDevice.fileAudioBuffer.count > 0) {
            while (audioDevice.isFileAudioLocked) {}
            audioDevice.isFileAudioLocked = true

            let numberOfFrameToExtract = audioDevice.fileAudioBuffer.count > inNumberFrames ? Int(inNumberFrames) : audioDevice.fileAudioBuffer.count
            // Get number of bytes from file audio based on microphone reading bytes
            let fileBuffer = Array(audioDevice.fileAudioBuffer.prefix(Int(numberOfFrameToExtract)))
            let micBuffer = (audioDevice.bufferList?.pointee.mBuffers.mData)!.toArray(to: Int16.self, capacity: Int(inNumberFrames))
            audioDevice.fileAudioBuffer.removeFirst(Int(numberOfFrameToExtract))

            var newBuffer = [Int16]()
              for i in 0..<Int(inNumberFrames) {
                  var temp = Double(micBuffer[i])
                  if (i < fileBuffer.count) {
                      temp = temp + Double(fileBuffer[i])
                  }
                  if (temp < Double(Int16.min)) {
                      temp = Double(Int16.min)
                  }
                  else if (temp > Double(Int16.max)) {
                      temp = Double(Int16.max)
                  }
                 newBuffer.append(Int16(temp))
            }

            let audioPointer = UnsafeMutableRawPointer(mutating: newBuffer)
            // OT Capture
            audioDevice.deviceAudioBus!.writeCaptureData(audioPointer, numberOfSamples: inNumberFrames)
            // Remove captured bytes
            audioDevice.isFileAudioLocked = false
        }
        else {
            audioDevice.deviceAudioBus!.writeCaptureData((audioDevice.bufferList?.pointee.mBuffers.mData)!, numberOfSamples: inNumberFrames)
        }
    }
    
    if audioDevice.bufferSize != audioDevice.bufferList?.pointee.mBuffers.mDataByteSize {
        audioDevice.bufferList?.pointee.mBuffers.mDataByteSize = audioDevice.bufferSize
    }
    
    updateRecordingDelay(withAudioDevice: audioDevice)
    
    return noErr
}

func updatePlayoutDelay(withAudioDevice audioDevice: CustomAudioDevice) {
    audioDevice.playoutDelayMeasurementCounter += 1
    if audioDevice.playoutDelayMeasurementCounter >= 100 {
        // Update HW and OS delay every second, unlikely to change
        audioDevice.playoutDelay = 0
        let session = AVAudioSession.sharedInstance()
        
        // HW output latency
        let interval = session.outputLatency
        audioDevice.playoutDelay += UInt32(interval * CustomAudioDevice.kToMicroSecond)
        // HW buffer duration
        let ioInterval = session.ioBufferDuration
        audioDevice.playoutDelay += UInt32(ioInterval * CustomAudioDevice.kToMicroSecond)
        audioDevice.playoutDelay += UInt32(audioDevice.playoutAudioUnitPropertyLatency * CustomAudioDevice.kToMicroSecond)
        // To ms
        if ( audioDevice.playoutDelay >= 500 ) {
            audioDevice.playoutDelay = (audioDevice.playoutDelay - 500) / 1000
        }
        audioDevice.playoutDelayMeasurementCounter = 0
    }
}

func updateRecordingDelay(withAudioDevice audioDevice: CustomAudioDevice) {
    audioDevice.recordingDelayMeasurementCounter += 1
    
    if audioDevice.recordingDelayMeasurementCounter >= 100 {
        audioDevice.recordingDelay = 0
        let session = AVAudioSession.sharedInstance()
        let interval = session.inputLatency
        
        audioDevice.recordingDelay += UInt32(interval * CustomAudioDevice.kToMicroSecond)
        let ioInterval = session.ioBufferDuration
        
        audioDevice.recordingDelay += UInt32(ioInterval * CustomAudioDevice.kToMicroSecond)
        audioDevice.recordingDelay += UInt32(audioDevice.recordingAudioUnitPropertyLatency * CustomAudioDevice.kToMicroSecond)
        
        audioDevice.recordingDelay = audioDevice.recordingDelay.advanced(by: -500) / 1000
        audioDevice.recordingDelayMeasurementCounter = 0
    }
}
