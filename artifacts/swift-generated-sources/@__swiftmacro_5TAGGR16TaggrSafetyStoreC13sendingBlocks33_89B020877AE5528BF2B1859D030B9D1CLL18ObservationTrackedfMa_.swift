{
    @storageRestrictions(initializes: _sendingBlocks)
    init(initialValue) {
      _sendingBlocks = initialValue
    }
    get {
      access(keyPath: \.sendingBlocks)
      return _sendingBlocks
    }
    set {
      guard shouldNotifyObservers(_sendingBlocks, newValue) else {
        _sendingBlocks = newValue
        return
      }
      withMutation(keyPath: \.sendingBlocks) {
        _sendingBlocks = newValue
      }
    }
    _modify {
      access(keyPath: \.sendingBlocks)
      _$observationRegistrar.willSet(self, keyPath: \.sendingBlocks)
      defer {
          _$observationRegistrar.didSet(self, keyPath: \.sendingBlocks)
      }
      yield &_sendingBlocks
    }
}

// original-source-range: /Volumes/KINGSTON/Offloaded/Desktop/TAGGR/ios/TAGGR/TAGGR/TaggrSafetyStore.swift:56:31-56:38
