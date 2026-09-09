{
    @storageRestrictions(initializes: _refreshing)
    init(initialValue) {
      _refreshing = initialValue
    }
    get {
      access(keyPath: \.refreshing)
      return _refreshing
    }
    set {
      guard shouldNotifyObservers(_refreshing, newValue) else {
        _refreshing = newValue
        return
      }
      withMutation(keyPath: \.refreshing) {
        _refreshing = newValue
      }
    }
    _modify {
      access(keyPath: \.refreshing)
      _$observationRegistrar.willSet(self, keyPath: \.refreshing)
      defer {
          _$observationRegistrar.didSet(self, keyPath: \.refreshing)
      }
      yield &_refreshing
    }
}

// original-source-range: /Volumes/KINGSTON/Offloaded/Desktop/TAGGR/ios/TAGGR/TAGGR/TaggrSafetyStore.swift:55:41-55:45
