//
//  ViewController.swift
//  movie-publisher-ios
//
//  Created by iujie on 24/11/2022.
//

import UIKit
import OpenTok

// Replace with your OpenTok API key
let kApiKey = ""
// Replace with your generated session ID
let kSessionId = ""
// Replace with your generated token
let kToken = ""


let kWidgetHeight: CGFloat = 240
let kWidgetWidth: CGFloat = 320
let screenSize: CGRect = UIScreen.main.bounds;
let screenWidth = screenSize.width;
let screenHeight = screenSize.height;
let videoPublisherName = "videoPublisher"

class ViewController: UIViewController {
    lazy var session: OTSession = {
        return OTSession(apiKey: kApiKey, sessionId: kSessionId, delegate: self)!
    }()

    var publisher: OTPublisher?
    var subscriber: OTSubscriber?
    var capturer: VideoCapturer?
    var videoLoaded: AVAsset?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        videoLoaded = loadVideoFromDocumentDirectory(fileName: "videoplayback")

        
        let settings = OTPublisherSettings()
        settings.name = videoPublisherName
        publisher = OTPublisher(delegate: self, settings: settings)
        publisher?.audioFallbackEnabled = false

        capturer = VideoCapturer(video: videoLoaded!)
        
        let customAudioDevice = CustomAudioDevice(video: videoLoaded!, videoCapturer: capturer!)
        OTAudioDeviceManager.setAudioDevice(customAudioDevice)
        
        publisher?.videoCapture = capturer
        
        doConnect()
    }
    
    /**
     * Asynchronously begins the session connect process. Some time later, we will
     * expect a delegate method to call us back with the results of this action.
     */
    private func doConnect() {
        var error: OTError?
        defer {
            process(error: error)
        }
        session.connect(withToken: kToken, error: &error)
    }
    
    /**
     * Sets up an instance of OTPublisher to use with this session. OTPubilsher
     * binds to the device camera and microphone, and will provide A/V streams
     * to the OpenTok session.
     */
    fileprivate func doPublish() {
        var error: OTError? = nil
        defer {
            process(error: error)
        }

        session.publish(publisher!, error: &error)
//        if let pubView = publisher!.view {
//               pubView.frame = CGRect(x: 0, y: 0, width: kWidgetWidth, height: kWidgetHeight)
//               view.addSubview(pubView)
//           }
    }
    
    fileprivate func doSubscribe(_ stream: OTStream) {
        var error: OTError?
        defer {
            process(error: error)
        }
        subscriber = OTSubscriber(stream: stream, delegate: self)
        
        session.subscribe(subscriber!, error: &error)
    }
    
    
    fileprivate func process(error err: OTError?) {
        if let e = err {
            showAlert(errorStr: e.localizedDescription)
        }
    }
    
    fileprivate func showAlert(errorStr err: String) {
        DispatchQueue.main.async {
            let controller = UIAlertController(title: "Error", message: err, preferredStyle: .alert)
            controller.addAction(UIAlertAction(title: "Ok", style: .default, handler: nil))
            self.present(controller, animated: true, completion: nil)
        }
    }
    fileprivate func loadVideoFromDocumentDirectory(fileName: String) -> AVAsset? {
    
       if let path = Bundle.main.path(forResource:fileName, ofType: "mp4", inDirectory: "") {
           let fileUrl = URL.init(fileURLWithPath: path)
           return AVAsset(url: fileUrl)
       }

       return nil
   }
    
}

extension ViewController: OTSessionDelegate {
    func sessionDidConnect(_ session: OTSession) {
        print("Session connected")
        doPublish()
    }
    
    func sessionDidDisconnect(_ session: OTSession) {
        print("Session disconnected")
    }
    
    func session(_ session: OTSession, streamCreated stream: OTStream) {
        print("Session streamCreated: \(stream.streamId)")
        doSubscribe(stream)
    }
    
    func session(_ session: OTSession, streamDestroyed stream: OTStream) {
        print("Session streamDestroyed: \(stream.streamId)")
    }
    
    func session(_ session: OTSession, didFailWithError error: OTError) {
        print("session Failed to connect: \(error.localizedDescription)")
    }
}

// MARK: - OTPublisher delegate callbacks
extension ViewController: OTPublisherDelegate {
    func publisher(_ publisher: OTPublisherKit, streamCreated stream: OTStream) {
        // Subscribe to own stream
        doSubscribe(stream)
    }
    
    func publisher(_ publisher: OTPublisherKit, streamDestroyed stream: OTStream) {
    }
    
    func publisher(_ publisher: OTPublisherKit, didFailWithError error: OTError) {
        print("Publisher failed: \(error.localizedDescription)")
    }
}

// MARK: - OTSubscriber delegate callbacks
extension ViewController: OTSubscriberDelegate {
    func subscriberDidConnect(toStream subscriberKit: OTSubscriberKit) {
        var width = screenWidth
        var height = screenHeight
        var x:CGFloat = 0
        var y:CGFloat = 0
        var bringToFront = false
        if (subscriber?.stream?.name == videoPublisherName) {
            width = kWidgetWidth
            height = kWidgetHeight
            x = screenWidth - kWidgetWidth - 12
            y = screenHeight - kWidgetHeight - 12
            bringToFront = true
        }
        if let subsView = subscriber?.view {
            subsView.frame = CGRect(x: x, y: y, width: width, height: height)
            view.addSubview(subsView)
            view.sendSubviewToBack(subsView);
            if (bringToFront) {
                view.bringSubviewToFront(subsView)
            }
        }

    }

    func subscriber(_ subscriber: OTSubscriberKit, didFailWithError error: OTError) {
        print("Subscriber failed: \(error.localizedDescription)")
    }

    func subscriberVideoDataReceived(_ subscriber: OTSubscriber) {
    }
}
