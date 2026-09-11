// Tests for the YGOPRODeck wire models.
//
//   flutter test test/api/ygo_models_test.dart
//
// The sample payloads below are verbatim slices of live cardinfo.php
// responses, including the parts that look like mistakes: "def" as a literal
// null on Links, every price as a string, has_effect as 0/1, and card_sets
// rows that repeat a set code. Tidying them up would defeat the point of the
// file, because those oddities are exactly what the parser exists to absorb.

import 'dart:convert';

import 'package:arcanum/data/api/ygo_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Decodes a JSON literal exactly the way the API client would, so the tests
/// exercise the same string-keyed map the network layer hands over.
Map<String, Object?> decode(String source) =>
    jsonDecode(source) as Map<String, Object?>;

/// Dark Magician, as returned by cardinfo.php?name=Dark Magician.
const String darkMagicianJson =
    '{"id":46986414,"name":"Dark Magician","typeline":["Spellcaster","Normal"],'
    '"type":"Normal Monster","humanReadableCardType":"Normal Monster",'
    '"frameType":"normal","desc":"\'\'The ultimate wizard in terms of attack '
    'and defense.\'\'","race":"Spellcaster","atk":2500,"def":2100,"level":7,'
    '"attribute":"DARK","archetype":"Dark Magician",'
    '"ygoprodeck_url":"https://ygoprodeck.com/card/dark-magician-4003",'
    '"card_sets":[{"set_name":"2016 Mega-Tins","set_code":"CT13-EN003",'
    '"set_rarity":"Ultra Rare","set_rarity_code":"(UR)","set_price":"6.97"}],'
    '"card_images":[{"id":46986414,"image_url":"https://images.ygoprodeck.com/'
    'images/cards/46986414.jpg","image_url_small":"https://images.ygoprodeck.'
    'com/images/cards_small/46986414.jpg","image_url_cropped":"https://images.'
    'ygoprodeck.com/images/cards_cropped/46986414.jpg"}],'
    '"card_prices":[{"cardmarket_price":"0.02","tcgplayer_price":"0.33",'
    '"ebay_price":"0.99","amazon_price":"14.45","coolstuffinc_price":"0.39"}]}';

/// Decode Talker, a Link monster whose def is a literal JSON null.
const String decodeTalkerJson =
    '{"id":1861629,"name":"Decode Talker","typeline":["Cyberse","Link","Effect"],'
    '"type":"Link Monster","humanReadableCardType":"Link Effect Monster",'
    '"frameType":"link","race":"Cyberse","atk":2300,"def":null,"level":0,'
    '"attribute":"DARK","archetype":"Code Talker","linkval":3,'
    '"linkmarkers":["Top","Bottom-Left","Bottom-Right"],"ygoprodeck_url":'
    '"https://ygoprodeck.com/card/decode-talker-8433"}';

void main() {
  group('YgoCard.fromJson', () {
    test('parses a monster card with every published field', () {
      final YgoCard card = YgoCard.fromJson(decode(darkMagicianJson));

      expect(card.id, 46986414);
      expect(card.name, 'Dark Magician');
      expect(card.typeLine, <String>['Spellcaster', 'Normal']);
      expect(card.type, 'Normal Monster');
      expect(card.humanReadableCardType, 'Normal Monster');
      expect(card.frameType, 'normal');
      expect(
        card.description,
        "''The ultimate wizard in terms of attack and defense.''",
      );
      expect(card.race, 'Spellcaster');
      expect(card.attack, 2500);
      expect(card.defense, 2100);
      expect(card.level, 7);
      expect(card.attribute, 'DARK');
      expect(card.archetype, 'Dark Magician');
      expect(
        card.ygoprodeckUrl,
        'https://ygoprodeck.com/card/dark-magician-4003',
      );

      expect(card.sets, hasLength(1));
      expect(card.sets.first.name, '2016 Mega-Tins');
      expect(card.sets.first.code, 'CT13-EN003');
      expect(card.sets.first.rarity, 'Ultra Rare');
      expect(card.sets.first.rarityCode, '(UR)');
      expect(card.sets.first.price, '6.97');

      expect(card.images, hasLength(1));
      expect(card.images.first.id, 46986414);
      expect(
        card.images.first.imageUrl,
        'https://images.ygoprodeck.com/images/cards/46986414.jpg',
      );
      expect(
        card.images.first.imageUrlSmall,
        'https://images.ygoprodeck.com/images/cards_small/46986414.jpg',
      );
      expect(
        card.images.first.imageUrlCropped,
        'https://images.ygoprodeck.com/images/cards_cropped/46986414.jpg',
      );
      expect(card.primaryImage, isNotNull);
      expect(
        card.thumbnailUrl,
        'https://images.ygoprodeck.com/images/cards_small/46986414.jpg',
      );

      expect(card.prices, isNotNull);
      expect(card.prices!.cardmarket, 0.02);
      expect(card.prices!.tcgplayer, 0.33);
      expect(card.prices!.ebay, 0.99);
      expect(card.prices!.amazon, 14.45);
      expect(card.prices!.coolstuffinc, 0.39);
      expect(card.bestUsdPrice, 0.33);

      // Not requested with &misc=yes, and never on a banlist.
      expect(card.miscInfo, isNull);
      expect(card.banlist, isNull);
      expect(card.isOnBanlist, isFalse);
      expect(card.linkValue, isNull);
      expect(card.linkMarkers, isEmpty);
      expect(card.scale, isNull);
      expect(card.pendulumDescription, isNull);
      expect(card.monsterDescription, isNull);
    });

    test('parses a Spell card with typeline, atk, def, level and attribute '
        'absent', () {
      final YgoCard card = YgoCard.fromJson(
        decode(
          '{"id":55144522,"name":"Pot of Greed","type":"Spell Card",'
          '"humanReadableCardType":"Normal Spell","frameType":"spell",'
          '"desc":"Draw 2 cards.","race":"Normal",'
          '"ygoprodeck_url":"https://ygoprodeck.com/card/pot-of-greed-4711"}',
        ),
      );

      expect(card.name, 'Pot of Greed');
      expect(card.type, 'Spell Card');
      expect(card.frameType, 'spell');
      expect(card.race, 'Normal');
      expect(card.typeLine, isEmpty);
      expect(card.attack, isNull);
      expect(card.defense, isNull);
      expect(card.level, isNull);
      expect(card.attribute, isNull);
      expect(card.archetype, isNull);
      expect(card.linkMarkers, isEmpty);
    });

    test('parses a Link monster whose def is an explicit JSON null', () {
      final YgoCard card = YgoCard.fromJson(decode(decodeTalkerJson));

      expect(card.name, 'Decode Talker');
      expect(card.frameType, 'link');
      expect(card.defense, isNull);
      expect(card.level, 0);
      expect(card.linkValue, 3);
      expect(card.linkMarkers, <String>['Top', 'Bottom-Left', 'Bottom-Right']);
      expect(card.attack, 2300);
      expect(card.bestUsdPrice, isNull);
      expect(card.thumbnailUrl, isNull);
    });

    test('parses a Pendulum monster with scale and both text boxes', () {
      final YgoCard card = YgoCard.fromJson(
        decode(
          '{"id":16178681,"name":"Performapal Skullcrobat Joker",'
          '"typeline":["Spellcaster","Pendulum","Effect"],'
          '"type":"Pendulum Effect Monster",'
          '"humanReadableCardType":"Pendulum Effect Monster",'
          '"frameType":"effect_pendulum","desc":"Monster text. Pendulum text.",'
          '"race":"Spellcaster","atk":1800,"def":100,"level":4,'
          '"attribute":"DARK","archetype":"Performapal","scale":8,'
          '"pend_desc":"You can target 1 Performapal monster you control.",'
          '"monster_desc":"When this card is Normal Summoned: add 1 card.",'
          '"ygoprodeck_url":"https://ygoprodeck.com/card/performapal-'
          'skullcrobat-joker-1377"}',
        ),
      );

      expect(card.frameType, 'effect_pendulum');
      expect(card.scale, 8);
      expect(card.pendulumDescription, contains('Performapal'));
      expect(card.monsterDescription, contains('Normal Summoned'));
      expect(card.level, 4);
      expect(card.defense, 100);
    });

    test('keeps both printings when two card_sets rows share a set code', () {
      final YgoCard card = YgoCard.fromJson(
        decode(
          '{"id":14558127,"name":"Ash Blossom & Joyous Spring",'
          '"type":"Effect Monster","card_sets":['
          '{"set_name":"25th Anniversary Rarity Collection",'
          '"set_code":"RA03-EN001","set_rarity":"Super Rare",'
          '"set_rarity_code":"(SR)","set_price":"4.20"},'
          '{"set_name":"25th Anniversary Rarity Collection",'
          '"set_code":"RA03-EN001","set_rarity":"Starlight Rare",'
          '"set_rarity_code":"(StR)","set_price":"120.00"}]}',
        ),
      );

      expect(card.sets, hasLength(2));
      expect(card.sets.map((YgoCardSet entry) => entry.code).toSet(), <String>{
        'RA03-EN001',
      });
      expect(
        card.sets.map((YgoCardSet entry) => entry.rarity).toList(),
        <String>['Super Rare', 'Starlight Rare'],
      );
      expect(card.sets.last.price, '120.00');
    });

    test('reads banlist_info when the card is restricted', () {
      final YgoCard card = YgoCard.fromJson(
        decode(
          '{"id":14558127,"name":"Ash Blossom & Joyous Spring",'
          '"type":"Effect Monster","banlist_info":{"ban_tcg":"Limited",'
          '"ban_ocg":"Semi-Limited"}}',
        ),
      );

      expect(card.isOnBanlist, isTrue);
      expect(card.banlist!.tcg, 'Limited');
      expect(card.banlist!.ocg, 'Semi-Limited');
      expect(card.banlist!.goat, isNull);
    });

    test('parses misc_info and keeps duplicate formats', () {
      final YgoCard card = YgoCard.fromJson(
        decode(
          '{"id":46986414,"name":"Dark Magician","type":"Normal Monster",'
          '"misc_info":[{"views":1029,"viewsweek":13,"upvotes":12,'
          '"downvotes":4,"konami_id":4041,"has_effect":0,'
          '"formats":["TCG Advanced","TCG Advanced","Duel Links"],'
          '"treated_as":"Dark Magician","tcg_date":"2002-03-08",'
          '"ocg_date":"2000-04-20","md_rarity":"Ultra Rare"}]}',
        ),
      );

      final YgoMiscInfo misc = card.miscInfo!;
      expect(misc.views, 1029);
      expect(misc.viewsWeek, 13);
      expect(misc.upvotes, 12);
      expect(misc.downvotes, 4);
      expect(misc.konamiId, 4041);
      expect(misc.hasEffect, isFalse);
      expect(misc.formats, <String>[
        'TCG Advanced',
        'TCG Advanced',
        'Duel Links',
      ]);
      expect(misc.uniqueFormats, <String>['TCG Advanced', 'Duel Links']);
      expect(misc.treatedAs, 'Dark Magician');
      expect(misc.tcgDate, '2002-03-08');
      expect(misc.ocgDate, '2000-04-20');
      expect(misc.mdRarity, 'Ultra Rare');
      expect(misc.betaName, isNull);
    });

    test('normalises the integer has_effect flag to a bool', () {
      final YgoCard card = YgoCard.fromJson(
        decode(
          '{"id":1,"misc_info":[{"has_effect":1,"formats":[],"konami_id":0}]}',
        ),
      );

      expect(card.miscInfo!.hasEffect, isTrue);
      expect(card.miscInfo!.konamiId, 0);
      expect(card.miscInfo!.views, isNull);
      expect(card.miscInfo!.uniqueFormats, isEmpty);
    });
  });

  group('malformed input', () {
    test('an empty card object degrades instead of throwing', () {
      final YgoCard card = YgoCard.fromJson(decode('{}'));

      expect(card.id, 0);
      expect(card.name, isEmpty);
      expect(card.type, isEmpty);
      expect(card.frameType, isEmpty);
      expect(card.description, isEmpty);
      expect(card.ygoprodeckUrl, isEmpty);
      expect(card.typeLine, isEmpty);
      expect(card.sets, isEmpty);
      expect(card.images, isEmpty);
      expect(card.prices, isNull);
      expect(card.miscInfo, isNull);
      expect(card.banlist, isNull);
      expect(card.bestUsdPrice, isNull);
      expect(card.primaryImage, isNull);
      expect(card.thumbnailUrl, isNull);
    });

    test('wrongly-typed fields degrade to null or an empty collection', () {
      final YgoCard card = YgoCard.fromJson(
        decode(
          '{"id":"not-a-number","name":42,"typeline":"Spellcaster",'
          '"atk":"lots","def":[],"level":"seven","linkmarkers":{},'
          '"card_sets":"oops","card_images":7,"banlist_info":"none",'
          '"misc_info":{},"scale":true}',
        ),
      );

      expect(card.id, 0);
      expect(card.name, '42');
      expect(card.attack, isNull);
      expect(card.defense, isNull);
      expect(card.level, isNull);
      expect(card.scale, isNull);
      expect(card.typeLine, isEmpty);
      expect(card.linkMarkers, isEmpty);
      expect(card.sets, isEmpty);
      expect(card.images, isEmpty);
      expect(card.banlist, isNull);
      expect(card.miscInfo, isNull);
    });

    test('a null price object yields no price block at all', () {
      final YgoCard nullEntry = YgoCard.fromJson(
        decode('{"id":1,"card_prices":[null]}'),
      );
      final YgoCard noEntries = YgoCard.fromJson(
        decode('{"id":1,"card_prices":[]}'),
      );

      expect(nullEntry.prices, isNull);
      expect(nullEntry.bestUsdPrice, isNull);
      expect(noEntries.prices, isNull);
      expect(noEntries.bestUsdPrice, isNull);
    });

    test('an empty data array parses to an empty page', () {
      final YgoPage page = YgoPage.fromJson(decode('{"data":[]}'));

      expect(page.cards, isEmpty);
      expect(page.isEmpty, isTrue);
      expect(page.length, 0);
      expect(page.meta, isNull);
      expect(page.hasNextPage, isFalse);
    });

    test('non-object entries in data are skipped rather than fatal', () {
      final YgoPage page = YgoPage.fromJson(
        decode('{"data":[null,{"id":1,"name":"Real"},[],"junk"]}'),
      );

      expect(page.cards, hasLength(1));
      expect(page.cards.single.name, 'Real');
    });

    test('a missing data key parses to an empty page', () {
      final YgoPage page = YgoPage.fromJson(decode('{"meta":{}}'));

      expect(page.cards, isEmpty);
      expect(page.meta, isNotNull);
      expect(page.meta!.totalRows, 0);
      expect(page.meta!.hasNextPage, isFalse);
    });
  });

  group('YgoCardPrices', () {
    test('reads every vendor from its string form', () {
      final YgoCardPrices prices = YgoCardPrices.fromJson(
        decode(
          '{"cardmarket_price":"0.02","tcgplayer_price":"0.33",'
          '"ebay_price":"0.99","amazon_price":"14.45",'
          '"coolstuffinc_price":"0.39"}',
        ),
      );

      expect(prices.cardmarket, 0.02);
      expect(prices.tcgplayer, 0.33);
      expect(prices.ebay, 0.99);
      expect(prices.amazon, 14.45);
      expect(prices.coolstuffinc, 0.39);
      expect(prices.bestUsd, 0.33);
      expect(prices.isEmpty, isFalse);
    });

    test('treats "0.00" as no market data rather than free', () {
      final YgoCardPrices prices = YgoCardPrices.fromJson(
        decode(
          '{"cardmarket_price":"0.00","tcgplayer_price":"0.00",'
          '"ebay_price":"0","amazon_price":"0.00","coolstuffinc_price":"0"}',
        ),
      );

      expect(prices.tcgplayer, isNull);
      expect(prices.cardmarket, isNull);
      expect(prices.bestUsd, isNull);
      expect(prices.isEmpty, isTrue);

      final YgoCard card = YgoCard.fromJson(
        decode('{"id":1,"card_prices":[{"tcgplayer_price":"0.00"}]}'),
      );
      expect(card.prices, isNotNull);
      expect(card.bestUsdPrice, isNull);
    });

    test('accepts a price sent as a number, an empty string or null', () {
      final YgoCardPrices prices = YgoCardPrices.fromJson(
        decode(
          '{"tcgplayer_price":5,"ebay_price":"","amazon_price":null,'
          '"cardmarket_price":"not a price"}',
        ),
      );

      expect(prices.tcgplayer, 5.0);
      expect(prices.ebay, isNull);
      expect(prices.amazon, isNull);
      expect(prices.cardmarket, isNull);
      expect(prices.bestUsd, 5.0);
      expect(prices.isEmpty, isFalse);
    });

    test(
      'falls back to another USD vendor only when tcgplayer has no data',
      () {
        final YgoCardPrices fallback = YgoCardPrices.fromJson(
          decode(
            '{"tcgplayer_price":"0.00","ebay_price":"3.10",'
            '"amazon_price":"9.99","coolstuffinc_price":"2.50"}',
          ),
        );
        final YgoCardPrices preferred = YgoCardPrices.fromJson(
          decode(
            '{"tcgplayer_price":"4.00","ebay_price":"1.10",'
            '"coolstuffinc_price":"0.50"}',
          ),
        );

        expect(fallback.bestUsd, 2.50);
        expect(preferred.bestUsd, 4.0);
      },
    );

    test('never uses the EUR price as a USD figure', () {
      final YgoCardPrices prices = YgoCardPrices.fromJson(
        decode('{"cardmarket_price":"2.00"}'),
      );

      expect(prices.cardmarket, 2.0);
      expect(prices.bestUsd, isNull);
      expect(prices.isEmpty, isFalse);
    });
  });

  group('YgoPage.fromJson', () {
    test('reads a page with a meta block', () {
      final YgoPage page = YgoPage.fromJson(
        decode(
          '{"data":[{"id":46986414,"name":"Dark Magician",'
          '"type":"Normal Monster"}],"meta":{"generated":"2026-01-01 10:00:00",'
          '"current_rows":1,"total_rows":13000,"rows_remaining":12999,'
          '"total_pages":130,"pages_remaining":129,'
          '"next_page":"https://db.ygoprodeck.com/api/v7/cardinfo.php?num=1'
          '&offset=1","next_page_offset":1}}',
        ),
      );

      expect(page.cards, hasLength(1));
      expect(page.cards.single.name, 'Dark Magician');
      expect(page.length, 1);

      final YgoMeta meta = page.meta!;
      expect(meta.generated, '2026-01-01 10:00:00');
      expect(meta.currentRows, 1);
      expect(meta.totalRows, 13000);
      expect(meta.rowsRemaining, 12999);
      expect(meta.totalPages, 130);
      expect(meta.pagesRemaining, 129);
      expect(meta.nextPageOffset, 1);
      expect(meta.nextPage, contains('offset=1'));
      expect(meta.hasNextPage, isTrue);
      expect(page.hasNextPage, isTrue);
    });

    test('tolerates a response with no meta key', () {
      final YgoPage page = YgoPage.fromJson(
        decode('{"data":[$darkMagicianJson]}'),
      );

      expect(page.cards, hasLength(1));
      expect(page.cards.single.id, 46986414);
      expect(page.meta, isNull);
      expect(page.hasNextPage, isFalse);
    });

    test('a full-database fetch has meta but no next_page', () {
      final YgoPage page = YgoPage.fromJson(
        decode(
          '{"data":[],"meta":{"current_rows":0,"total_rows":1,'
          '"rows_remaining":0,"total_pages":1,"pages_remaining":0}}',
        ),
      );

      expect(page.meta!.nextPage, isNull);
      expect(page.meta!.nextPageOffset, isNull);
      expect(page.meta!.hasNextPage, isFalse);
    });

    test('a garbled meta block degrades to zeroes, not an exception', () {
      final YgoPage page = YgoPage.fromJson(
        decode('{"data":[],"meta":{"total_rows":"many","next_page":7}}'),
      );

      expect(page.meta!.totalRows, 0);
      expect(page.meta!.nextPage, '7');
      expect(page.hasNextPage, isTrue);
    });

    test('the Link monster sample survives a page round-trip', () {
      final YgoPage page = YgoPage.fromJson(
        decode('{"data":[$decodeTalkerJson],"meta":{"current_rows":1}}'),
      );

      expect(page.cards.single.defense, isNull);
      expect(page.cards.single.linkMarkers, hasLength(3));
      expect(page.cards.single.prices, isNull);
      expect(page.cards.single.level, 0);
    });
  });
}
