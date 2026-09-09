{
    @storageRestrictions(initializes: _agreements)
    init(initialValue) {
      _agreements = initialValue
    }
    get {
      access(keyPath: \.agreements)
      return _agreements
    }
    set {
      guard shouldNotifyObservers(_agreements, newValue) else {
        _agreements = newValue
        return
      }
      withMutation(keyPath: \.agreements) {
        _agreements = newValue
      }
    }
    _modify {
      access(keyPath: \.agreements)
      _$observationRegistrar.willSet(self, keyPath: \.agreements)
      defer {
          _$observationRegistrar.didSet(self, keyPath: \.agreements)
      }
      yield &_agreements
    }
}

// original-source-range: /Volumes/KINGSTON/Offloaded/Desktop/TAGGR/ios/TAGGR/TAGGR/TaggrSafetyStore.swift:52:48-52:48
