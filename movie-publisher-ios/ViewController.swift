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
    var mySubscriber: OTSubscriber?
    var capturer: VideoCapturer?
    var videoLoaded: AVAsset?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        videoLoaded = loadVideoFromDocumentDirectory(fileName: "vonage_roadshow")
        doConnect()
    }
    
    private func doConnect() {
        var error: OTError?
        defer {
            process(error: error)
        }
        session.connect(withToken: kToken, error: &error)
    }
    
    fileprivate func doPublish() {
        var error: OTError? = nil
        defer {
            process(error: error)
        }

        let settings = OTPublisherSettings()
        settings.name = videoPublisherName
        
        publisher = OTPublisher(delegate: self, settings: settings)
        publisher?.audioFallbackEnabled = false

        capturer = VideoCapturer(video: videoLoaded!)
        
        let customAudioDevice = CustomAudioDevice(video: videoLoaded!, videoCapturer: capturer!)
        OTAudioDeviceManager.setAudioDevice(customAudioDevice)
        
        publisher?.videoCapture = capturer
        
        session.publish(publisher!, error: &error)
    
    }
    fileprivate func doSubscribe(_ stream: OTStream, isMe: Bool) {
        var error: OTError?
        defer {
            process(error: error)
        }
        let tempSubscriber = OTSubscriber(stream: stream, delegate: self)
        if (!isMe) {
            subscriber = tempSubscriber
        }
        else {
            mySubscriber = tempSubscriber
        }
        session.subscribe(tempSubscriber!, error: &error)
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
    
    fileprivate func cleanupSubscriber() {
       subscriber?.view?.removeFromSuperview()
       subscriber = nil
    }
    
    fileprivate func cleanupPublisher() {
        publisher?.view?.removeFromSuperview()
        publisher = nil
    }
 
// For disconnect button
    @IBAction func didClick(_ sender: UIButton) {
        var error: OTError?
        defer {
            process(error: error)
        }
        if (sender.titleLabel!.text == "Disconnect") {
            if (publisher != nil) {
                session.unpublish(publisher!, error: &error)
            }
            session.disconnect(&error)
            sender.setTitle("Connect", for: .normal)
        }
        else {
            doConnect()
            sender.setTitle("Disconnect", for: .normal)
        }
    }
}

extension ViewController: OTSessionDelegate {
    func sessionDidConnect(_ session: OTSession) {
        print("Session connected")
        doPublish()
    }
    
    func sessionDidDisconnect(_ session: OTSession) {
        print("Session disconnected")
        cleanupPublisher()
        cleanupSubscriber()
    }
    
    func session(_ session: OTSession, streamCreated stream: OTStream) {
        print("Session streamCreated: \(stream.streamId)")
        doSubscribe(stream, isMe: false)
    }
    
    func session(_ session: OTSession, streamDestroyed stream: OTStream) {
        print("Session streamDestroyed: \(stream.streamId)")
        cleanupSubscriber()
    }
    
    func session(_ session: OTSession, didFailWithError error: OTError) {
        print("session Failed to connect: \(error.localizedDescription)")
    }
}

// MARK: - OTPublisher delegate callbacks
extension ViewController: OTPublisherDelegate {
    func publisher(_ publisher: OTPublisherKit, streamCreated stream: OTStream) {
        print("Published")
        doSubscribe(stream, isMe: true)
    }
    
    func publisher(_ publisher: OTPublisherKit, streamDestroyed stream: OTStream) {
        cleanupPublisher()
    }
    
    func publisher(_ publisher: OTPublisherKit, didFailWithError error: OTError) {
        print("Publisher failed: \(error.localizedDescription)")
    }
}

// MARK: - OTSubscriber delegate callbacks
extension ViewController: OTSubscriberDelegate {
    func subscriberDidConnect(toStream subscriberKit: OTSubscriberKit) {
        if (subscriberKit.stream?.name == videoPublisherName) {
            subscriberKit.audioVolume = 0
            if let subsView = mySubscriber?.view {
                subsView.frame = CGRect(x: screenWidth - kWidgetWidth - 12, y: screenHeight - kWidgetHeight - 12, width: kWidgetWidth, height: kWidgetHeight)
                view.addSubview(subsView)
                view.bringSubviewToFront(subsView)
            }
        }
        else {
            if let subsView = subscriber?.view {
                subsView.frame = CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight)
                view.addSubview(subsView)
                view.sendSubviewToBack(subsView);
            }
        }
    }

    func subscriber(_ subscriber: OTSubscriberKit, didFailWithError error: OTError) {
        print("Subscriber failed: \(error.localizedDescription)")
    }

    func subscriberVideoDataReceived(_ subscriber: OTSubscriber) {
    }
}

