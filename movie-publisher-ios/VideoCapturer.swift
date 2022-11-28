//
//  VideoCapturer.swift
//  movie-publisher-ios
//
//  Created by iujie on 24/11/2022.
//

import OpenTok
import AVFoundation

protocol FrameCapturerMetadataDelegate {
    func finishPreparingFrame(_ videoFrame: OTVideoFrame?)
}

class VideoCapturer: NSObject, OTVideoCapture {
    var videoContentHint: OTVideoContentHint = .none
    var captureSession: AVCaptureSession?
    
    var videoCaptureConsumer: OTVideoCaptureConsumer?
    var delegate: FrameCapturerMetadataDelegate?
    
    fileprivate let captureQueue = DispatchQueue(label: "ot-video-capture")
    fileprivate var videoInput: AVAsset
    fileprivate var videoOutput: AVAssetReaderOutput?
    fileprivate var capturing = false
    fileprivate var videoFrame = OTVideoFrame(format: OTVideoFormat(argbWithWidth: 0, height: 0))
    fileprivate var lastTimeStamp: CMTime = CMTime()

    
    init(video: AVAsset) {
        videoInput = video
    }

    
    func initCapture() {
      }
      
      func releaseCapture() {
      }
      
      func start() -> Int32 {
          capturing = true
          captureQueue.async {
              while(self.capturing) {
                  self.setupCaptureSession()
              }
          }
          return 0
      }
      
      func stop() -> Int32 {
          capturing = false
          return 0
      }
      
      func isCaptureStarted() -> Bool {
          return capturing
      }
      
      func captureSettings(_ videoFormat: OTVideoFormat) -> Int32 {
          videoFormat.pixelFormat = .NV12
           return 0
      }

}

extension VideoCapturer {
    private func setupCaptureSession() {
        do {
        /* allocate assetReader */
        let avAssetReader = try AVAssetReader(asset: videoInput)
            
        /* get video track(s) from video asset */
        let videoTrack = videoInput.tracks(withMediaType: .video)
        let audioTrack = videoInput.tracks(withMediaType: .audio)
            
        let videoSize = videoTrack[0].naturalSize
            
            print("videosize width: " , videoSize.width)
            print("videosize height: " , videoSize.height)

            let format = OTVideoFormat.init(nv12WithWidth: UInt32(videoSize.width), height: UInt32(videoSize.height))
            videoFrame.format = format
            
            let videoSetting:NSDictionary = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
                        
            /* construct the actual track output and add it to the asset reader */
            let assetReaderVideoOutput = AVAssetReaderTrackOutput(track: videoTrack[0], outputSettings: videoSetting as? [String : Any]
            )
            let assetReaderAudioOutput = AVAssetReaderTrackOutput(track: audioTrack[0], outputSettings: nil)

            var i = 0
            if (avAssetReader.canAdd(assetReaderVideoOutput) && avAssetReader.canAdd(assetReaderAudioOutput)) {
                avAssetReader.add(assetReaderVideoOutput)
                avAssetReader.add(assetReaderAudioOutput)

                print("video and audio asset added to output")

                if (avAssetReader.startReading()) {
                    var buffer: CMSampleBuffer?
//                    var audioBuffer: CMSampleBuffer
                    while (capturing && avAssetReader.status == AVAssetReader.Status.reading) {
                        let startTime = CACurrentMediaTime()
                        buffer = assetReaderVideoOutput.copyNextSampleBuffer()
                        if (buffer == nil) {return}
//                        audioBuffer = assetReaderAudioOutput.copyNextSampleBuffer()!
                        i+=1
                        var timingInfo = CMSampleTimingInfo.invalid
                        CMSampleBufferGetSampleTimingInfo(buffer!,at: 0, timingInfoOut: &timingInfo)
                        let oldTS = lastTimeStamp
                        let currentTS = timingInfo.presentationTimeStamp


                        let previousTime = Double(oldTS.value) / Double(oldTS.timescale)
                        let currentTime = Double(currentTS.value) / Double(currentTS.timescale)

                        lastTimeStamp = timingInfo.presentationTimeStamp

                        sendSampleBuffer(buffer:buffer!, timeStamp: timingInfo.presentationTimeStamp)

                        let finishTime = CACurrentMediaTime();
                        let decodeTime = finishTime - startTime;
                        let sleepTime = currentTime - previousTime - decodeTime
                        Thread.sleep(forTimeInterval: sleepTime)

                    }
                }
                else {
                    print("could not start reading asset")
                    print("asset reader status:, \(avAssetReader.status)")
                }
            }
            else {
                print("could not add asset to output")
            }
        }
        catch {
            print("error", error)
        }
    }
    
    private func sendSampleBuffer(buffer: CMSampleBuffer, timeStamp: CMTime) {
        let imageBuffer = CMSampleBufferGetImageBuffer(buffer)
        CVPixelBufferLockBaseAddress(imageBuffer!, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)))
        
        // clear previous pointers
        videoFrame.planes?.count = 0
        
        // copy new pointers
        if !CVPixelBufferIsPlanar(imageBuffer!) {
                videoFrame.planes?.addPointer(CVPixelBufferGetBaseAddress(imageBuffer!))
            } else {
                for idx in 0..<CVPixelBufferGetPlaneCount(imageBuffer!) {
                    videoFrame.planes?.addPointer(CVPixelBufferGetBaseAddressOfPlane(imageBuffer!, idx))
                }
        }
        videoFrame.orientation = .up
        videoFrame.timestamp = timeStamp
        videoCaptureConsumer?.consumeFrame(videoFrame)

        CVPixelBufferUnlockBaseAddress(imageBuffer!, CVPixelBufferLockFlags(rawValue: CVOptionFlags(0)));

    }
    
}

