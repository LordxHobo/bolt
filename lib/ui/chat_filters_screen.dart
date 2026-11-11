import 'package:flutter/material.dart';

import '../core/services.dart';
import 'widgets.dart';

/// Settings → Chat → Filters: what chat hides or highlights (only for you).
class ChatFiltersScreen extends StatelessWidget {
  const ChatFiltersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Services.settings;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Chat filters')),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            SwitchListTile(
              title: const Text('Hide bots'),
              subtitle: const Text('Nightbot, StreamElements, Botrix and other common bots'),
              value: s.hideBots,
              onChanged: s.setHideBots,
            ),
            const SectionHeader('Hidden people'),
            _ListEditor(
              keyName: 'mutedUsers',
              values: s.mutedUsers,
              hint: 'Add a username',
              empty: 'Nobody. You can also long-press a message → Hide messages.',
            ),
            const SectionHeader('Hidden words'),
            _ListEditor(
              keyName: 'mutedWords',
              values: s.mutedWords,
              hint: 'Add a word or phrase',
              empty: 'Messages containing these are hidden.',
            ),
            const SectionHeader('Highlight words'),
            _ListEditor(
              keyName: 'highlightWords',
              values: s.highlightWords,
              hint: 'Add a word, e.g. your nickname',
              empty: 'Messages containing these get an amber highlight.',
            ),
          ],
        ),
      ),
    );
  }
}

class _ListEditor extends StatefulWidget {
  const _ListEditor({required this.keyName, required this.values, required this.hint, required this.empty});

  final String keyName;
  final List<String> values;
  final String hint;
  final String empty;

  @override
  State<_ListEditor> createState() => _ListEditorState();
}

class _ListEditorState extends State<_ListEditor> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _add() {
    final v = _field.text.trim();
    if (v.isEmpty) return;
    Services.settings.setFilterList(widget.keyName, [...widget.values, v]);
    _field.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.values.isEmpty)
            Text(widget.empty,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.6)))
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final v in widget.values)
                  InputChip(
                    label: Text(v),
                    onDeleted: () => Services.settings
                        .setFilterList(widget.keyName, [...widget.values]..remove(v)),
                  ),
              ],
            ),
          const SizedBox(height: 8),
          TextField(
            controller: _field,
            autocorrect: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _add(),
            onTapOutside: (_) => FocusScope.of(context).unfocus(),
            decoration: InputDecoration(
              isDense: true,
              hintText: widget.hint,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(icon: const Icon(Icons.add_rounded), onPressed: _add),
            ),
          ),
        ],
      ),
    );
  }
}
