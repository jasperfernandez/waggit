class CommitModel {
  const CommitModel({
    required this.hash,
    required this.message,
    required this.date,
    required this.author,
  });

  final String hash;
  final String message;
  final DateTime date;
  final String author;
}
