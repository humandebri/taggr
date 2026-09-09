{
    @storageRestrictions(initializes: _clock)
    init(initialValue) {
      _clock = initialValue
    }
    get {
      access(keyPath: \.clock)
      return _clock
    }
    set {
      guard shouldNotifyObservers(_clock, newValue) else {
        _clock = newValue
        return
      }
      withMutation(keyPath: \.clock) {
        _clock = newValue
      }
    }
    _modify {
      access(keyPath: \.clock)
      _$observationRegistrar.willSet(self, keyPath: \.clock)
      defer {
          _$observationRegistrar.didSet(self, keyPath: \.clock)
      }
      yield &_clock
    }
}

// original-source-range: /Volumes/KINGSTON/Offloaded/Desktop/TAGGR/ios/TAGGR/TAGGR/TaggrSafetyStore.swift:57:28-57:36
