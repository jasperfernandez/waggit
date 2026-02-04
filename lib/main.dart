import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_size/window_size.dart';

import 'models/daily_accomplishment.dart';
import 'services/gemini_service.dart';
import 'services/git_service.dart';
import 'services/pdf_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _configureWindow();
  runApp(const AccomplishmentApp());
}

void _configureWindow() {
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    return;
  }
  const windowSize = Size(1100, 800);
  setWindowTitle('Waggit by Jasper Fernandez');
  setWindowMinSize(windowSize);
  setWindowMaxSize(Size.infinite);
  setWindowFrame(const Rect.fromLTWH(0, 0, 1100, 800));
}

class AccomplishmentApp extends StatelessWidget {
  const AccomplishmentApp({super.key});

  @override
  Widget build(BuildContext context) {
    final baseTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF2F2D4A),
        brightness: Brightness.light,
        primary: const Color(0xFF2F2D4A),
        secondary: const Color(0xFFE08F62),
        surface: const Color(0xFFF5F1EB),
      ),
      useMaterial3: true,
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(fontSize: 16),
        bodyMedium: TextStyle(fontSize: 14),
      ),
    );

    return MaterialApp(
      title: 'Waggit - Work Accomplishment Generator for Git commits',
      debugShowCheckedModeBanner: false,
      theme: baseTheme.copyWith(
        scaffoldBackgroundColor: const Color(0xFFF5F1EB),
      ),
      home: const AccomplishmentHomePage(),
    );
  }
}

class AccomplishmentHomePage extends StatefulWidget {
  const AccomplishmentHomePage({super.key});

  @override
  State<AccomplishmentHomePage> createState() => _AccomplishmentHomePageState();
}

class _AccomplishmentHomePageState extends State<AccomplishmentHomePage> {
  static const Duration _geminiMinInterval = Duration(minutes: 1);

  final _authorController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _gitService = GitService();
  final _pdfService = PdfService();
  final _dateFormatter = DateFormat('MMM dd, yyyy');

  String? _repoPath;
  String? _outputPath;
  DateTime? _startDate;
  DateTime? _endDate;
  bool _isBusy = false;
  String _statusMessage = 'Choose a repo and date range to begin.';
  String? _lastReportPath;

  bool _cancelRequested = false;
  bool _saveNowRequested = false;

  @override
  void dispose() {
    _authorController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _pickRepository() async {
    final selection = await FilePicker.platform.getDirectoryPath();
    if (selection == null) {
      return;
    }
    setState(() {
      _repoPath = selection;
      _statusMessage = 'Repository selected.';
    });
  }

  Future<void> _pickDate({required bool isStart}) async {
    final initialDate = isStart ? _startDate : _endDate;
    final now = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: initialDate ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      helpText: isStart ? 'Select start date' : 'Select end date',
    );

    if (selected == null) {
      return;
    }
    setState(() {
      if (isStart) {
        _startDate = selected;
      } else {
        _endDate = selected;
      }
    });
  }

  Future<void> _pickOutputPath() async {
    final defaultName = _defaultReportFileName();
    final docDir = await getApplicationDocumentsDirectory();
    final outputPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save PDF report',
      fileName: defaultName,
      initialDirectory: docDir.path,
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );

    if (outputPath == null) {
      return;
    }

    setState(() {
      _outputPath = outputPath;
    });
  }

  Future<void> _generateReport() async {
    final repoPath = _repoPath;
    final author = _authorController.text.trim();
    final apiKey = _apiKeyController.text.trim();
    final startDate = _startDate;
    final endDate = _endDate;
    var outputPath = _outputPath;

    if (repoPath == null || repoPath.isEmpty) {
      _setStatus('Please select a repository directory.');
      return;
    }
    if (author.isEmpty) {
      _setStatus('Please enter an author name.');
      return;
    }
    if (apiKey.isEmpty) {
      _setStatus('Please enter a Gemini API key.');
      return;
    }
    if (startDate == null || endDate == null) {
      _setStatus('Please pick both start and end dates.');
      return;
    }
    if (endDate.isBefore(startDate)) {
      _setStatus('End date must be on or after the start date.');
      return;
    }
    outputPath ??= await _resolveOutputPath();
    if (outputPath == null || outputPath.isEmpty) {
      _setStatus('Please choose a save location for the PDF report.');
      return;
    }

    setState(() {
      _isBusy = true;
      _statusMessage = 'Extracting commits from git history...';
      _lastReportPath = null;
      _cancelRequested = false;
      _saveNowRequested = false;
    });

    try {
      final commitsByDay = await _gitService.fetchCommitsByDay(
        repoPath: repoPath,
        author: author,
        startDate: startDate,
        endDate: endDate,
      );

      if (commitsByDay.isEmpty) {
        _setStatus('No commits found for that author and date range.');
        return;
      }

      final gemini = GeminiService(apiKey: apiKey);
      final accomplishments = <DailyAccomplishment>[];
      String? geminiError;

      final sortedDays = commitsByDay.keys.toList()..sort();
      for (final day in sortedDays) {
        if (_cancelRequested || _saveNowRequested) {
          break;
        }
        final canProceed = await _throttleGemini();
        if (!canProceed || _cancelRequested || _saveNowRequested) {
          break;
        }
        _setStatus('Summarizing ${_dateFormatter.format(day)}...');
        final commitMessages = commitsByDay[day]!
            .map((commit) => commit.message)
            .toList();

        try {
          final bullets = await gemini.summarizeDay(
            dateLabel: _dateFormatter.format(day),
            commitMessages: commitMessages,
          );
          accomplishments.add(DailyAccomplishment(date: day, bullets: bullets));
        } on GeminiServiceException catch (error) {
          geminiError = error.message;
          break;
        }
      }

      if (_cancelRequested) {
        _setStatus('Generation canceled. No report was saved.');
        return;
      }
      if (accomplishments.isEmpty) {
        if (geminiError != null) {
          _setStatus('Gemini error: $geminiError');
        } else {
          _setStatus('No accomplishments collected to save yet.');
        }
        return;
      }

      if (geminiError != null) {
        _setStatus('Gemini error encountered. Saving partial report...');
      } else {
        _setStatus('Generating PDF report...');
      }
      final reportFile = await _pdfService.generateReport(
        accomplishments: accomplishments,
        outputPath: outputPath,
        title: 'Git Accomplishments Report',
      );

      setState(() {
        _lastReportPath = reportFile.path;
      });
      if (geminiError != null) {
        _setStatus(
          'Report saved to ${reportFile.path} (partial, Gemini error: $geminiError)',
        );
      } else {
        _setStatus('Report saved to ${reportFile.path}');
      }
    } on GitServiceException catch (error) {
      _setStatus(error.message);
    } on FileSystemException catch (error) {
      _setStatus('File error: ${error.message}');
    } catch (error) {
      _setStatus('Unexpected error: $error');
    } finally {
      setState(() {
        _isBusy = false;
      });
    }
  }

  Future<String> _defaultOutputPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/${_defaultReportFileName()}';
  }

  String _defaultReportFileName() {
    final timestamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
    return 'git_accomplishments_$timestamp.pdf';
  }

  Future<String?> _resolveOutputPath() async {
    final defaultPath = await _defaultOutputPath();
    final outputPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save PDF report',
      fileName: File(defaultPath).uri.pathSegments.last,
      initialDirectory: File(defaultPath).parent.path,
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (outputPath == null) {
      return null;
    }
    setState(() {
      _outputPath = outputPath;
    });
    return outputPath;
  }

  void _setStatus(String message) {
    setState(() {
      _statusMessage = message;
    });
  }

  Future<bool> _throttleGemini() async {
    final targetTime = DateTime.now().add(_geminiMinInterval);
    while (DateTime.now().isBefore(targetTime)) {
      if (_cancelRequested || _saveNowRequested) {
        return false;
      }
      final remaining = targetTime.difference(DateTime.now());
      _setStatus('Waiting ${remaining.inSeconds}s for Gemini rate limit...');
      await Future.delayed(const Duration(seconds: 1));
    }
    return true;
  }

  void _requestCancel() {
    if (!_isBusy) {
      return;
    }
    setState(() {
      _cancelRequested = true;
    });
    _setStatus('Canceling...');
  }

  void _requestSaveNow() {
    if (!_isBusy) {
      return;
    }
    setState(() {
      _saveNowRequested = true;
    });
    _setStatus('Saving with collected accomplishments...');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFFF5F1EB), Color(0xFFE9E1D8)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth > 900;
                return SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 32,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 980),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _HeaderSection(isWide: isWide),
                          const SizedBox(height: 28),
                          _InputCard(
                            repoPath: _repoPath,
                            onPickRepo: _pickRepository,
                            authorController: _authorController,
                            apiKeyController: _apiKeyController,
                            startDate: _startDate,
                            endDate: _endDate,
                            outputPath: _outputPath,
                            onPickOutput: _pickOutputPath,
                            onPickStart: () => _pickDate(isStart: true),
                            onPickEnd: () => _pickDate(isStart: false),
                          ),
                          const SizedBox(height: 20),
                          _ActionRow(
                            isBusy: _isBusy,
                            onGenerate: _generateReport,
                            onCancel: _requestCancel,
                            onSaveNow: _requestSaveNow,
                            statusMessage: _statusMessage,
                            lastReportPath: _lastReportPath,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderSection extends StatelessWidget {
  const _HeaderSection({required this.isWide});

  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Waggit by Jasper Fernandez',
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'Summarize git history into daily accomplishment bullets and export a polished PDF report.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: const Color(0xFF5E5B73),
                ),
              ),
            ],
          ),
        ),
        if (isWide)
          Container(
            width: 220,
            height: 140,
            margin: const EdgeInsets.only(left: 24),
            decoration: BoxDecoration(
              color: const Color(0xFF2F2D4A),
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x332F2D4A),
                  blurRadius: 18,
                  offset: Offset(0, 12),
                ),
              ],
            ),
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Daily Insights',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Track outcomes, not just commits.',
                    style: TextStyle(color: Color(0xFFCDC7F6), fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _InputCard extends StatelessWidget {
  const _InputCard({
    required this.repoPath,
    required this.onPickRepo,
    required this.authorController,
    required this.apiKeyController,
    required this.startDate,
    required this.endDate,
    required this.outputPath,
    required this.onPickOutput,
    required this.onPickStart,
    required this.onPickEnd,
  });

  final String? repoPath;
  final VoidCallback onPickRepo;
  final TextEditingController authorController;
  final TextEditingController apiKeyController;
  final DateTime? startDate;
  final DateTime? endDate;
  final String? outputPath;
  final VoidCallback onPickOutput;
  final VoidCallback onPickStart;
  final VoidCallback onPickEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateFormatter = DateFormat('MMM dd, yyyy');

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A2F2D4A),
            blurRadius: 20,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Inputs', style: theme.textTheme.titleLarge),
          const SizedBox(height: 18),
          _InputRow(
            label: 'Repository',
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    repoPath ?? 'No repository selected',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: repoPath == null ? const Color(0xFF8D879C) : null,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                FilledButton(
                  onPressed: onPickRepo,
                  child: const Text('Pick folder'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _InputRow(
            label: 'Author',
            child: TextField(
              controller: authorController,
              decoration: const InputDecoration(
                hintText: 'Jasper Fernandez',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 14),
          _InputRow(
            label: 'Date Range',
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onPickStart,
                    child: Text(
                      startDate == null
                          ? 'Start date'
                          : dateFormatter.format(startDate!),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: onPickEnd,
                    child: Text(
                      endDate == null
                          ? 'End date'
                          : dateFormatter.format(endDate!),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _InputRow(
            label: 'Output PDF',
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    outputPath ?? 'Default location (Documents)',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: outputPath == null
                          ? const Color(0xFF8D879C)
                          : null,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                OutlinedButton(
                  onPressed: onPickOutput,
                  child: const Text('Choose'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _InputRow(
            label: 'Gemini API Key',
            child: TextField(
              controller: apiKeyController,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: 'AIza...',
                border: OutlineInputBorder(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InputRow extends StatelessWidget {
  const _InputRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 18),
        Expanded(child: child),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.isBusy,
    required this.onGenerate,
    required this.onSaveNow,
    required this.onCancel,
    required this.statusMessage,
    required this.lastReportPath,
  });

  final bool isBusy;
  final VoidCallback onGenerate;
  final VoidCallback onSaveNow;
  final VoidCallback onCancel;
  final String statusMessage;
  final String? lastReportPath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: const Color(0xFF2F2D4A),
        boxShadow: const [
          BoxShadow(
            color: Color(0x332F2D4A),
            blurRadius: 18,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Generate report',
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                  ),
                ),
              ),
              FilledButton(
                onPressed: isBusy ? null : onGenerate,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE08F62),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 14,
                  ),
                ),
                child: isBusy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Text('Generate'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton(
                onPressed: isBusy ? onSaveNow : null,
                style: OutlinedButton.styleFrom(
                  backgroundColor: const Color(0xFFE08F62),
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFFE08F62)),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                ),
                child: const Text('Save now'),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: isBusy ? onCancel : null,
                style: TextButton.styleFrom(
                  backgroundColor: const Color(0xFFF5F1EB),
                  foregroundColor: const Color(0xFF1B1A2E),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                ),
                child: const Text('Cancel'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            statusMessage,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: const Color(0xFFF5F1EB),
            ),
          ),
          if (lastReportPath != null) ...[
            const SizedBox(height: 8),
            SelectableText(
              lastReportPath!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFFCDC7F6),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
