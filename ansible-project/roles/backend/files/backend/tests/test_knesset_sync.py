import knesset_sync

LIVE_SHAPED_RESPONSE = {
    "odata.metadata": "https://knesset.gov.il/Odata/ParliamentInfo.svc/$metadata#KNS_Faction",
    "value": [
        {"FactionID": 911, "Name": "אין נתונים", "KnessetNum": 1,
         "StartDate": "1900-01-01T00:00:00", "FinishDate": None,
         "IsCurrent": True, "LastUpdatedDate": "2019-01-24T11:45:06.46"},
        {"FactionID": 1096, "Name": "הליכוד ", "KnessetNum": 25,
         "StartDate": "2022-11-15T00:00:00", "FinishDate": None,
         "IsCurrent": True, "LastUpdatedDate": "2024-10-07T12:14:59.083"},
        {"FactionID": 1101, "Name": "יהדות התורה", "KnessetNum": 25,
         "StartDate": "2022-11-15T00:00:00", "FinishDate": None,
         "IsCurrent": True, "LastUpdatedDate": "2024-10-07T12:22:42.103"},
    ],
}


def test_parse_current_factions_drops_legacy_placeholder_and_strips_names():
    factions = knesset_sync.parse_current_factions(LIVE_SHAPED_RESPONSE)
    assert len(factions) == 2
    names = {f['name'] for f in factions}
    assert 'הליכוד' in names  # trailing space stripped
    assert 'אין נתונים' not in names
    ids = {f['knesset_faction_id'] for f in factions}
    assert ids == {'1096', '1101'}


def test_parse_current_factions_empty_response():
    assert knesset_sync.parse_current_factions({'value': []}) == []
