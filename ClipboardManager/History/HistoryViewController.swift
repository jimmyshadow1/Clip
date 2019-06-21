//
//  HistoryViewController.swift
//  ClipboardManager
//
//  Created by Riley Testut on 6/10/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit
import MobileCoreServices

import ClipKit
import Roxas

class HistoryViewController: UITableViewController
{
    private var dataSource: RSTFetchedResultsTableViewPrefetchingDataSource<PasteboardItem, UIImage>!
    
    private let _undoManager = UndoManager()
    
    private var prototypeCell: ClippingTableViewCell!
    private var cachedHeights = [NSManagedObjectID: CGFloat]()
    
    private weak var selectedItem: PasteboardItem?
    
    private var updateTimer: Timer?
    private var fetchLimitSettingObservation: NSKeyValueObservation?
    
    private lazy var dateComponentsFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.second, .minute, .hour, .day]
        return formatter
    }()
    
    override var undoManager: UndoManager? {
        return _undoManager
    }
    
    override func viewDidLoad()
    {
        super.viewDidLoad()
        
        self.updateDataSource()
        
        self.tableView.contentInset.top = 8
        self.tableView.estimatedRowHeight = 0
        
        self.prototypeCell = ClippingTableViewCell.instantiate(with: ClippingTableViewCell.nib!)
        self.tableView.register(ClippingTableViewCell.nib, forCellReuseIdentifier: RSTCellContentGenericCellIdentifier)
        
        DatabaseManager.shared.persistentContainer.viewContext.undoManager = self.undoManager
        
        NotificationCenter.default.addObserver(self, selector: #selector(HistoryViewController.didEnterBackground(_:)), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(HistoryViewController.willEnterForeground(_:)), name: UIApplication.willEnterForegroundNotification, object: nil)
        
        self.fetchLimitSettingObservation = UserDefaults.shared.observe(\.historyLimit) { [weak self] (defaults, change) in
            self?.updateDataSource()
        }
        
        self.startUpdating()
    }
    
    override func viewDidAppear(_ animated: Bool)
    {
        super.viewDidAppear(animated)
        
        self.becomeFirstResponder()
    }
    
    override func viewWillDisappear(_ animated: Bool)
    {
        super.viewWillDisappear(animated)
        
        self.resignFirstResponder()
    }
    
    override var canBecomeFirstResponder: Bool
    {
        return true
    }
}

extension HistoryViewController
{
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool
    {
        let supportedActions = [#selector(UIResponderStandardEditActions.copy(_:)), #selector(UIResponderStandardEditActions.delete(_:)), #selector(HistoryViewController._share(_:))]
        
        let isSupported = supportedActions.contains(action)
        return isSupported
    }
    
    @objc override func copy(_ sender: Any?)
    {
        guard let item = self.selectedItem else { return }
        
        PasteboardMonitor.shared.copy(item)
    }
    
    @objc override func delete(_ sender: Any?)
    {
        guard let item = self.selectedItem else { return }
        
        // Use the main view context so we can undo this operation easily.
        // Saving a context can mess with its undo history, so we only save main context when we enter background.
        item.isMarkedForDeletion = true
    }
    
    @objc func _share(_ sender: Any?)
    {
        guard let item = self.selectedItem else { return }
        
        let activityViewController = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        self.present(activityViewController, animated: true, completion: nil)
    }
}

private extension HistoryViewController
{
    func makeDataSource() -> RSTFetchedResultsTableViewPrefetchingDataSource<PasteboardItem, UIImage>
    {
        let fetchRequest = PasteboardItem.historyFetchRequest()
        fetchRequest.returnsObjectsAsFaults = false
        fetchRequest.relationshipKeyPathsForPrefetching = [#keyPath(PasteboardItem.preferredRepresentation)]
        
        let dataSource = RSTFetchedResultsTableViewPrefetchingDataSource<PasteboardItem, UIImage>(fetchRequest: fetchRequest, managedObjectContext: DatabaseManager.shared.persistentContainer.viewContext)
        dataSource.cellConfigurationHandler = { [weak self] (cell, item, indexPath) in
            let cell = cell as! ClippingTableViewCell
            cell.contentLabel.isHidden = false
            cell.contentImageView.isHidden = true
            
            self?.updateDate(for: cell, item: item)
            
            if let representation = item.preferredRepresentation
            {
                switch representation.type
                {
                case .text:
                    cell.titleLabel.text = NSLocalizedString("Text", comment: "")
                    cell.contentLabel.text = representation.stringValue
                    
                case .attributedText:
                    cell.titleLabel.text = NSLocalizedString("Text", comment: "")
                    cell.contentLabel.text = representation.attributedStringValue?.string
                    
                case .url:
                    cell.titleLabel.text = NSLocalizedString("URL", comment: "")
                    cell.contentLabel.text = representation.urlValue?.absoluteString
                    
                case .image:
                    cell.titleLabel.text = NSLocalizedString("Image", comment: "")
                    cell.contentLabel.isHidden = true
                    cell.contentImageView.isHidden = false
                    cell.contentImageView.isIndicatingActivity = true
                }
            }
            else
            {
                cell.titleLabel.text = NSLocalizedString("Unknown", comment: "")
                cell.contentLabel.isHidden = true
            }
            
            if indexPath.row < UserDefaults.shared.historyLimit.rawValue
            {
                cell.bottomConstraint.isActive = true
            }
            else
            {
                // Make it not active so we can collapse the cell to a height of 0 without auto layout errors.
                cell.bottomConstraint.isActive = false
            }
        }
        
        dataSource.prefetchHandler = { (item, indexPath, completionHandler) in
            guard let representation = item.preferredRepresentation, representation.type == .image else { return nil }
            
            return RSTBlockOperation() { (operation) in
                guard let image = representation.imageValue?.resizing(toFill: CGSize(width: 500, height: 500)) else { return completionHandler(nil, nil) }
                completionHandler(image, nil)
            }
        }
        
        dataSource.prefetchCompletionHandler = { (cell, image, indexPath, error) in
            DispatchQueue.main.async {
                let cell = cell as! ClippingTableViewCell

                if let image = image
                {
                    cell.contentImageView.image = image
                }
                else
                {
                    cell.contentImageView.image = nil
                }

                cell.contentImageView.isIndicatingActivity = false
            }
        }
        
        return dataSource
    }
    
    func updateDataSource()
    {
        self.stopUpdating()
        
        self.dataSource = self.makeDataSource()
        self.tableView.dataSource = self.dataSource
        self.tableView.prefetchDataSource = self.dataSource
        self.tableView.reloadData()
        
        self.startUpdating()
    }
    
    func updateDate(for cell: ClippingTableViewCell, item: PasteboardItem)
    {
        if Date().timeIntervalSince(item.date) < 2
        {
            cell.dateLabel.text = NSLocalizedString("now", comment: "")
        }
        else
        {
            cell.dateLabel.text = self.dateComponentsFormatter.string(from: item.date, to: Date())
        }
    }
    
    func showMenu(at indexPath: IndexPath)
    {
        guard let cell = self.tableView.cellForRow(at: indexPath) as? ClippingTableViewCell else { return }
        
        let item = self.dataSource.item(at: indexPath)
        self.selectedItem = item
        
        let targetRect = cell.clippingView.frame
        
        self.becomeFirstResponder()
        
        UIMenuController.shared.setTargetRect(targetRect, in: cell)
        UIMenuController.shared.setMenuVisible(true, animated: true)
    }
    
    func startUpdating()
    {
        self.stopUpdating()
        
        self.updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] (timer) in
            guard let self = self else { return }
            
            for indexPath in self.tableView.indexPathsForVisibleRows ?? []
            {
                guard let cell = self.tableView.cellForRow(at: indexPath) as? ClippingTableViewCell else { continue }
                
                let item = self.dataSource.item(at: indexPath)
                self.updateDate(for: cell, item: item)
            }
        }
    }
    
    func stopUpdating()
    {
        self.updateTimer?.invalidate()
        self.updateTimer = nil
    }
}

private extension HistoryViewController
{
    @objc func didEnterBackground(_ notification: Notification)
    {
        // Save any pending changes to disk.
        if DatabaseManager.shared.persistentContainer.viewContext.hasChanges
        {
            do
            {
                try DatabaseManager.shared.persistentContainer.viewContext.save()
            }
            catch
            {
                print("Failed to save view context.", error)
            }
        }
        
        self.undoManager?.removeAllActions()
        
        self.stopUpdating()
    }
    
    @objc func willEnterForeground(_ notification: Notification)
    {
        self.startUpdating()
    }
    
    @IBAction func unwindToHistoryViewController(_ segue: UIStoryboardSegue)
    {
    }
}

extension HistoryViewController
{
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat
    {
        // It's far *far* easier to simply set row height to 0 for cells beyond history limit
        // than to actually limit fetched results to the correct number live (with insertions and deletions).
        guard indexPath.row < UserDefaults.shared.historyLimit.rawValue else { return 0.0 }
        
        let item = self.dataSource.item(at: indexPath)
        
        if let height = self.cachedHeights[item.objectID]
        {
            return height
        }
        
        let portraitScreenHeight = UIScreen.main.coordinateSpace.convert(UIScreen.main.bounds, to: UIScreen.main.fixedCoordinateSpace).height
        let maximumHeight: CGFloat
        
        if item.preferredRepresentation?.type == .image
        {
            maximumHeight = portraitScreenHeight / 2
        }
        else
        {
            maximumHeight = portraitScreenHeight / 3
        }
        
        let widthConstraint = self.prototypeCell.contentView.widthAnchor.constraint(equalToConstant: tableView.bounds.width)
        let heightConstraint = self.prototypeCell.contentView.heightAnchor.constraint(lessThanOrEqualToConstant: maximumHeight)
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
        defer { NSLayoutConstraint.deactivate([widthConstraint, heightConstraint]) }
        
        self.dataSource.cellConfigurationHandler(self.prototypeCell, item, indexPath)
        
        let size = self.prototypeCell.contentView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        self.cachedHeights[item.objectID] = size.height
        return size.height
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath)
    {
        self.showMenu(at: indexPath)
    }
}
