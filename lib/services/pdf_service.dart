import 'dart:io';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/daily_accomplishment.dart';

class PdfService {
  Future<File> generateReport({
    required List<DailyAccomplishment> accomplishments,
    required String outputPath,
    required String title,
  }) async {
    final doc = pw.Document();
    final sorted = [...accomplishments]
      ..sort((a, b) => a.date.compareTo(b.date));

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (context) {
          return [
            pw.Text(
              title,
              style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 12),
            for (final day in sorted) ...[
              pw.Text(
                _formatDate(day.date),
                style: pw.TextStyle(
                  fontSize: 14,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.indigo,
                ),
              ),
              pw.SizedBox(height: 6),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: day.bullets
                    .map(
                      (bullet) => pw.Padding(
                        padding: const pw.EdgeInsets.only(bottom: 4),
                        child: pw.Bullet(text: bullet),
                      ),
                    )
                    .toList(),
              ),
              pw.SizedBox(height: 14),
            ],
          ];
        },
      ),
    );

    final file = File(outputPath);
    await file.writeAsBytes(await doc.save());
    return file;
  }

  String _formatDate(DateTime date) {
    final month = _monthName(date.month);
    final day = date.day.toString().padLeft(2, '0');
    return '$month $day, ${date.year}';
  }

  String _monthName(int month) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return months[month - 1];
  }
}
