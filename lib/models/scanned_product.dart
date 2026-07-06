/// Représente un produit ajouté au panier après un scan réussi.
class ScannedProduct {
  final String label;
  final double price;
  final String imagePath;

  ScannedProduct({
    required this.label,
    required this.price,
    required this.imagePath,
  });
}
