{
    @storageRestrictions(initializes: _blockOverrides)
    init(initialValue) {
      _blockOverrides = initialValue
    }
    get {
      access(keyPath: \.blockOverrides)
      return _blockOverrides
    }
    set {
      guard shouldNotifyObservers(_blockOverrides, newValue) else {
        _blockOverrides = newValue
        return
      }
      withMutation(keyPath: \.blockOverrides) {
        _blockOverrides = newValue
      }
    }
    _modify {
      access(keyPath: \.blockOverrides)
      _$observationRegistrar.willSet(self, keyPath: \.blockOverrides)
      defer {
          _$observationRegistrar.didSet(self, keyPath: \.blockOverrides)
      }
      yield &_blockOverrides
    }
}

// original-source-range: /Volumes/KINGSTON/Offloaded/Desktop/TAGGR/ios/TAGGR/TAGGR/TaggrSafetyStore.swift:53:57-53:57
