@ObservationIgnored private let _$observationRegistrar = Observation.ObservationRegistrar()

internal nonisolated func access<$s5TAGGR16TaggrSafetyStore10ObservablefMm_6MemberfMu_>(
  keyPath: KeyPath<TaggrSafetyStore, $s5TAGGR16TaggrSafetyStore10ObservablefMm_6MemberfMu_>
) {
  _$observationRegistrar.access(self, keyPath: keyPath)
}

internal nonisolated func withMutation<$s5TAGGR16TaggrSafetyStore10ObservablefMm_6MemberfMu0_, $s5TAGGR16TaggrSafetyStore10ObservablefMm_14MutationResultfMu_>(
  keyPath: KeyPath<TaggrSafetyStore, $s5TAGGR16TaggrSafetyStore10ObservablefMm_6MemberfMu0_>,
  _ mutation: () throws -> $s5TAGGR16TaggrSafetyStore10ObservablefMm_14MutationResultfMu_
) rethrows -> $s5TAGGR16TaggrSafetyStore10ObservablefMm_14MutationResultfMu_ {
  try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
}

private nonisolated func shouldNotifyObservers<$s5TAGGR16TaggrSafetyStore10ObservablefMm_6MemberfMu1_>(_ lhs: $s5TAGGR16TaggrSafetyStore10ObservablefMm_6MemberfMu1_, _ rhs: $s5TAGGR16TaggrSafetyStore10ObservablefMm_6MemberfMu1_) -> Bool {
    true
}

private nonisolated func shouldNotifyObservers<$s5TAGGR16TaggrSafetyStore10ObservablefMm_6MemberfMu2_: Equatable>(_ lhs: $s5TAGGR16TaggrSafetyStore10ObservablefMm_6MemberfMu2_, _ rhs: $s5TAGGR16TaggrSafetyStore10ObservablefMm_6MemberfMu2_) -> Bool {
    lhs != rhs
}

private nonisolated func shouldNotifyObservers<$s5TAGGR16TaggrSafetyStore10ObservablefMm_6MemberfMu3_: AnyObject>(_ lhs: $s5TAGGR16TaggrSafetyStore10ObservablefMm_6MemberfMu3_, _ rhs: $s5TAGGR16TaggrSafetyStore10ObservablefMm_6MemberfMu3_) -> Bool {
    lhs !== rhs
}

private nonisolated func shouldNotifyObservers<$s5TAGGR16TaggrSafetyStore10ObservablefMm_6MemberfMu4_: Equatable & AnyObject>(_ lhs: $s5TAGGR16TaggrSafetyStore10ObservablefMm_6MemberfMu4_, _ rhs: $s5TAGGR16TaggrSafetyStore10ObservablefMm_6MemberfMu4_) -> Bool {
    lhs != rhs
}

// original-source-range: /Volumes/KINGSTON/Offloaded/Desktop/TAGGR/ios/TAGGR/TAGGR/TaggrSafetyStore.swift:170:1-170:1
