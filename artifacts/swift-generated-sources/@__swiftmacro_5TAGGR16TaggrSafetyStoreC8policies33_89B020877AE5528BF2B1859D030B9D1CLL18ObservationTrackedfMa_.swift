{
    @storageRestrictions(initializes: _policies)
    init(initialValue) {
      _policies = initialValue
    }
    get {
      access(keyPath: \.policies)
      return _policies
    }
    set {
      guard shouldNotifyObservers(_policies, newValue) else {
        _policies = newValue
        return
      }
      withMutation(keyPath: \.policies) {
        _policies = newValue
      }
    }
    _modify {
      access(keyPath: \.policies)
      _$observationRegistrar.willSet(self, keyPath: \.policies)
      defer {
          _$observationRegistrar.didSet(self, keyPath: \.policies)
      }
      yield &_policies
    }
}

// original-source-range: /Volumes/KINGSTON/Offloaded/Desktop/TAGGR/ios/TAGGR/TAGGR/TaggrSafetyStore.swift:51:54-51:54
