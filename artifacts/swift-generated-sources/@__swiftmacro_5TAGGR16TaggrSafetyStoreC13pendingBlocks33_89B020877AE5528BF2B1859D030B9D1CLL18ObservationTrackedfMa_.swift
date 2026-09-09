{
    @storageRestrictions(initializes: _pendingBlocks)
    init(initialValue) {
      _pendingBlocks = initialValue
    }
    get {
      access(keyPath: \.pendingBlocks)
      return _pendingBlocks
    }
    set {
      guard shouldNotifyObservers(_pendingBlocks, newValue) else {
        _pendingBlocks = newValue
        return
      }
      withMutation(keyPath: \.pendingBlocks) {
        _pendingBlocks = newValue
      }
    }
    _modify {
      access(keyPath: \.pendingBlocks)
      _$observationRegistrar.willSet(self, keyPath: \.pendingBlocks)
      defer {
          _$observationRegistrar.didSet(self, keyPath: \.pendingBlocks)
      }
      yield &_pendingBlocks
    }
}

// original-source-range: /Volumes/KINGSTON/Offloaded/Desktop/TAGGR/ios/TAGGR/TAGGR/TaggrSafetyStore.swift:54:51-54:51
