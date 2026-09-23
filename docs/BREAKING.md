# Breaking changes

Every version that breaks a consumer is named here, with each `buf breaking` finding written out
word for word and the reason beside it. `tools/breaking-gate` reads this file: a finding that is
not declared fails the gate and names itself, in the pull request and again at the tag.

That is the whole mechanism. There is no flag to pass and nothing to set in the environment — the
only way past the gate is to describe what breaks, in the file a consumer reads when they upgrade.

**Read this before bumping a pin.** Each section says what to change in calling code, because a
contract that breaks without saying how to move is a contract that gets pinned to an old version
for ever.

---

## v1.0.20

### `bool has_location` is gone from two identity messages

```
Previously present field "10" with name "has_location" on message "GetUserProfileResponse" was deleted.
Previously present field "8" with name "has_location" on message "GetMerchantInfoResponse" was deleted.
```

**Why.** A message field carries its own presence, so the flag only restated what `location`
already said. In C++ that restatement is fatal: protoc generates `has_location()` for the message
field's presence *and* `has_location()` for the boolean, and no C++ compiler accepts two members
with the same name.

```
identity.pb.h:2292:22: error: class member cannot be redeclared
identity.pb.h:2266:22: note: previous declaration is here
```

Every other language names the two apart — Go `GetHasLocation()` against `GetLocation()`, Python a
field against `HasField("location")` — so eight services never felt it, and the ninth, written in
C++, could not compile this contract at all. Field numbers 10 and 8 are `reserved`, so neither can
come back meaning something else.

**What to change.** Ask the field itself whether it is set:

| language | before | after |
| --- | --- | --- |
| C# | `if (!response.HasLocation)` | `if (response.Location is null)` |
| Go | `if !r.GetHasLocation()` | `if r.GetLocation() == nil` |
| Python | `if not response.has_location` | `if not response.HasField("location")` |
| TypeScript | `if (!response.has_location)` | `if (!response.location)` |
| C++ | — | `if (!response.has_location())` — now unambiguous |

**One thing to check on the way.** A producer that always sent `location` and used the flag to say
whether it meant anything must stop sending it. identity did exactly that: an address that had
never been geocoded went out as `{0, 0}`, and the flag was the only thing separating it from a real
point. Left that way, removing the flag turns every unplaced address into a coordinate in the
Atlantic — and dispatch would route couriers to it. identity now omits the field entirely when
there is no location; `test/grpc_location_presence.spec.ts` holds that.

**Deploy identity before order.** In between, an order still reading the removed flag sees the
proto3 default `false` and refuses to dispatch: inconvenient, and closed. The other way round, a
new order against an old identity sees a location that is never null and dispatches to the ocean.
