import Foundation

struct TmuxInteractivePTYConnectionState<Owner: AnyObject> {
    private struct Entry {
        let binding: TmuxInteractiveSubscriptionBinding
        let owner: Owner
    }

    private(set) var isRetired = false
    private var entriesBySubscriptionID = [String: Entry]()

    var count: Int {
        entriesBySubscriptionID.count
    }

    mutating func install(
        binding: TmuxInteractiveSubscriptionBinding,
        owner: Owner
    ) -> Bool {
        guard isRetired == false,
              binding.subscriptionID.isEmpty == false,
              entriesBySubscriptionID[binding.subscriptionID] == nil else {
            return false
        }
        entriesBySubscriptionID[binding.subscriptionID] = Entry(
            binding: binding,
            owner: owner
        )
        return true
    }

    func owner(for binding: TmuxInteractiveSubscriptionBinding) -> Owner? {
        guard isRetired == false,
              let entry = entriesBySubscriptionID[binding.subscriptionID],
              entry.binding == binding else {
            return nil
        }
        return entry.owner
    }

    mutating func remove(binding: TmuxInteractiveSubscriptionBinding) -> Owner? {
        guard isRetired == false,
              let entry = entriesBySubscriptionID[binding.subscriptionID],
              entry.binding == binding else {
            return nil
        }
        entriesBySubscriptionID.removeValue(forKey: binding.subscriptionID)
        return entry.owner
    }

    mutating func retire() -> [Owner] {
        guard isRetired == false else {
            return []
        }
        isRetired = true
        let owners = entriesBySubscriptionID.values.map(\.owner)
        entriesBySubscriptionID.removeAll(keepingCapacity: false)
        return owners
    }
}
