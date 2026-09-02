# ADR-008 Evidence Principles
Status: Accepted (2026-09-02)

## Context
BLEUnlock 把「訊號消失」直接當「使用者離開」並鎖定，是「Signal is lost」誤鎖抱怨的根源；同時藍牙關閉也會被當成離開。

## Decision
**Absence of evidence is not evidence of absence.**
- Sensor failure（`SensorHealth != healthy`）不得驅動任何 proximity action；以 `SensorHealth` 軸表達，不透過切換 `PresenceState`。
- 裝置沉默是「失去證據」（`unknown(.evidenceExpired)`），不是 absence；silence-based lock 需要第二個 supporting signal（輸入閒置已知且夠長），缺席則不動作。
- `departureThenSilent` 是「比突然沉默更強的 absence 證據」，不是「確認離開」；evidence provenance 隨 snapshot 保留，Policy 可獨立調整。
- Required preconditions 與 supporting evidence 在型別上分開；前者 unknown 一律不動作，後者 unknown 由規則決定。

## Consequences
接受的代價：藍牙不可用時即使人已離開也不會鎖；UI 必須顯示自動保護已暫停。
