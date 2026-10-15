import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/images.dart';
import '../data/models.dart';
import '../data/web_shops.dart';

/// Slika proizvoda: iz baze/sajta, inače Open Food Facts po barkodu, inače ikonica.
class ProductImage extends StatelessWidget {
  final String? url;
  final String? ean;
  final double size;
  const ProductImage({super.key, this.url, this.ean, this.size = 56});

  Widget _icon(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(size * 0.12)),
        child: Icon(Icons.shopping_basket_outlined, size: size * 0.45, color: Theme.of(context).colorScheme.outline),
      );

  // fotografije pakovanja su na beloj pozadini – bela podloga i u tamnoj temi, da slike izgledaju ujednačeno
  Widget _net(BuildContext context, String u) => Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * 0.06),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(size * 0.12),
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: CachedNetworkImage(
          imageUrl: u,
          fit: BoxFit.contain,
          memCacheHeight: (size * MediaQuery.devicePixelRatioOf(context)).round(),
          placeholder: (c, _) => const SizedBox.shrink(),
          errorWidget: (c, url, e) {
            debugPrint('slika nije učitana ($url): $e');
            return Icon(Icons.shopping_basket_outlined, size: size * 0.45, color: Colors.grey);
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (url != null && url!.isNotEmpty) return _net(context, url!);
    final e = ean;
    if (e == null || e.isEmpty) return _icon(context);
    final cached = ProductImages.instance.cached(e);
    if (cached != null) return _net(context, cached);
    if (ProductImages.instance.known(e)) return _icon(context);
    return FutureBuilder<String?>(
      future: ProductImages.instance.forEan(e),
      builder: (c, s) {
        if (s.hasError) debugPrint('slika za $e: ${s.error}');
        return s.data == null ? _icon(c) : _net(c, s.data!);
      },
    );
  }
}

/// Zašto nema lokacije + dugme koje otvara odgovarajuća podešavanja telefona.
class LocationNotice extends StatelessWidget {
  final String problem;
  final Future<bool> Function()? fix;
  const LocationNotice(this.problem, this.fix, {super.key});

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(child: Text('Udaljenost nije prikazana: $problem', style: Theme.of(context).textTheme.bodySmall)),
        if (fix != null) TextButton(onPressed: fix, child: const Text('Uključi')),
      ]);
}

/// lanci za koje postoji logo u `assets/logos/<slug>.png`
const _logos = {
  'aroma', 'dm', 'gigatron', 'gomex', 'idea', 'kengur', 'laguna', 'lidl', 'lilly', 'matijevic', 'maxi', 'metro',
  'okov', 'planeta-sport', 'proleter', 'sumadija', 'tehnomanija', 'univerexport', 'uspon', 'veropoulos',
};

/// Logo lanca na beloj pločici; lanci bez logotipa dobijaju inicijale u boji lanca.
class ChainLogo extends StatelessWidget {
  final Chain? chain;
  final double size;
  const ChainLogo(this.chain, {super.key, this.size = 40});

  static String initials(String name) {
    final words = name.split(RegExp(r'[\s/]+')).where((w) => w.isNotEmpty && w[0].toUpperCase() != w[0].toLowerCase());
    return words.take(2).map((w) => w[0].toUpperCase()).join();
  }

  @override
  Widget build(BuildContext context) {
    final c = chain;
    final r = BorderRadius.circular(size * 0.22);
    if (c != null && _logos.contains(c.slug)) {
      return Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * 0.08),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: r,
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: Image.asset('assets/logos/${c.slug}.png', fit: BoxFit.contain, filterQuality: FilterQuality.medium),
      );
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c?.color ?? Colors.grey, borderRadius: r),
      child: Text(initials(c?.name ?? '?'),
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: size * 0.38, height: 1)),
    );
  }
}

/// Red u listi rezultata: slika levo, desno naziv, proizvođač i cena.
class ProductTile extends StatelessWidget {
  final ProductHit p;
  final VoidCallback onTap;
  const ProductTile(this.p, {super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mine = p.bestSelected;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          ProductImage(url: p.image, ean: p.ean, size: 72),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.titleMedium),
              if (p.brand.isNotEmpty)
                Text(p.brand, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 4),
              Text.rich(TextSpan(children: [
                if (mine != null) ...[
                  TextSpan(
                      text: 'od ${fmtPrice(mine)}',
                      style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold, color: t.colorScheme.primary)),
                  TextSpan(
                      text: '  ·  ${plural(p.offers, 'lanac', 'lanca', 'lanaca')}',
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ] else
                  TextSpan(
                      text: 'nije u tvojim radnjama · od ${fmtPrice(p.bestAll)}',
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.outline)),
              ])),
            ]),
          ),
        ]),
      ),
    );
  }
}

class WebProductTile extends StatelessWidget {
  final WebProduct p;
  final Chain? chain;
  final String shopName;
  final VoidCallback onTap;
  const WebProductTile(this.p, {super.key, required this.chain, required this.shopName, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          ProductImage(url: p.image, size: 72),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.titleMedium),
              const SizedBox(height: 4),
              Row(children: [
                ChainLogo(chain, size: 20),
                const SizedBox(width: 6),
                Text(shopName, style: t.textTheme.bodySmall),
                const SizedBox(width: 8),
                Text(fmtPrice(p.price),
                    style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold, color: t.colorScheme.primary)),
              ]),
              if (!p.available) Text('nema na stanju', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
            ]),
          ),
        ]),
      ),
    );
  }
}

Future<void> openUrl(BuildContext context, String url) async {
  final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ne mogu da otvorim $url')));
  }
}

class PriceText extends StatelessWidget {
  final Offer o;
  const PriceText(this.o, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
      Text(fmtPrice(o.effective),
          style: t.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold, color: o.onSale ? Colors.red.shade700 : null)),
      if (o.onSale)
        Text(fmtPrice(o.price),
            style: t.textTheme.bodySmall?.copyWith(decoration: TextDecoration.lineThrough)),
    ]);
  }
}

class EmptyHint extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  const EmptyHint(this.icon, this.text, {super.key, this.action});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 12), action!],
          ]),
        ),
      );
}
