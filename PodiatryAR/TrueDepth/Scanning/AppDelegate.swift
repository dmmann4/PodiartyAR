import ARKit
import UIKit
import Combine

//@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
	var window: UIWindow?
    
    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        reloadScans()
        
        return true
    }
    
    private(set) var scans: [ScanType] = []
    
    private var _scansContainerURL: URL {
        return URL(fileURLWithPath: NSHomeDirectory().appending("/Documents"))
    }
    
    func reloadScans() {
        let urls = try! FileManager.default.contentsOfDirectory(at: _scansContainerURL, includingPropertiesForKeys: nil, options: [])
        let plyURLs = urls
            .filter { $0.pathExtension == "ply" }
            .filter { !$0.lastPathComponent.contains("-mesh") }
        
        scans = plyURLs.map { url in ScanType(plyPath: url.path) }
                .sorted { $0.dateCreated.compare($1.dateCreated) == .orderedDescending }
    }
    
    func add(_ scan: ScanType) {
        if scan.plyPath == nil {
            do {
                try scan.write(toContainerPath: _scansContainerURL.path)
                scans.insert(scan, at: 0)
            } catch {
                print("Error saving scan: \(error)")
            }
        }
    }
    
    func remove(_ scan: ScanType) {
        if let index = scans.firstIndex(of: scan) {
            do {
                try scan.deleteFiles()
                scans.remove(at: index)
            } catch {
                print("Error deleting files: \(error)")
            }
        }
    }
    
    func createBPLYScanDirectory() -> String {
        let directoryName = ScanType.string(from: Date())
        let absoluteDirectory = _scansContainerURL.appendingPathComponent(directoryName)
        
        try? FileManager.default.createDirectory(at: absoluteDirectory, withIntermediateDirectories: false, attributes: nil)
        
        return absoluteDirectory.path
    }
    
}
