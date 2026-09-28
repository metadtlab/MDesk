import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../models/file_model.dart';

class RemoteTransferProgressSource {
  const RemoteTransferProgressSource(this.controller, {this.label});
  final JobController controller;
  final String? label;
}

class _TransferJob {
  const _TransferJob(this.source, this.job);
  final RemoteTransferProgressSource source;
  final JobProgress job;
}

/// Render above the workspace, independently of the retained connection pages.
/// The same JobControllers own transfers in single and split view.
class RemoteTransferProgress extends StatelessWidget {
  const RemoteTransferProgress({
    super.key,
    required this.sources,
    this.bottom = 16,
    this.onInteractionStart,
    this.onInteractionEnd,
  });

  final List<RemoteTransferProgressSource> sources;
  final double bottom;
  final VoidCallback? onInteractionStart;
  final VoidCallback? onInteractionEnd;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) return const SizedBox.shrink();
    return Positioned.fill(child: Obx(() {
      final seen = <JobController>{};
      final entries = <_TransferJob>[
        for (final source in sources)
          if (seen.add(source.controller))
            for (final job in source.controller.jobTable)
              if ((job.isRemoteDropDownload || job.isDirectDownload) &&
                  job.type == JobType.transfer &&
                  job.state != JobState.done)
                _TransferJob(source, job),
      ]..sort((a, b) => b.job.id.compareTo(a.job.id));
      if (entries.isEmpty) return const SizedBox.shrink();
      final jobs = entries.map((entry) => entry.job).toList();
      final visible = entries.take(3).toList();
      return Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, bottom),
        child: Align(
          alignment: Alignment.bottomRight,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Listener(
              onPointerDown: (_) => onInteractionStart?.call(),
              onPointerUp: (_) => onInteractionEnd?.call(),
              onPointerCancel: (_) => onInteractionEnd?.call(),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  key: const ValueKey('remote-transfer-progress-panel'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surface
                        .withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .outline
                            .withValues(alpha: 0.35)),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 16,
                          offset: const Offset(0, 8))
                    ],
                  ),
                  child: SingleChildScrollView(
                    primary: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(
                              jobs.every((job) => job.isDirectDownload)
                                  ? Icons.file_download_outlined
                                  : Icons.file_upload_outlined,
                              size: 18,
                              color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(
                                  jobs.every((job) => job.isDirectDownload)
                                      ? '다운로드 폴더로 복사 중'
                                      : jobs.every(
                                              (job) => job.isRemoteDropDownload)
                                          ? '피원격자 다운로드 폴더로 복사 중'
                                          : '파일 복사 중',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700))),
                        ]),
                        const SizedBox(height: 10),
                        for (final entry in visible) _buildItem(context, entry),
                        if (entries.length > visible.length)
                          Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                  '+${entries.length - visible.length} more',
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.65),
                                      fontSize: 11))),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }));
  }

  Widget _buildItem(BuildContext context, _TransferJob entry) {
    final job = entry.job;
    final progress = _remoteDropProgressValue(job);
    final progressText = progress == null
        ? null
        : '${(progress * 100).clamp(0, 100).toStringAsFixed(0)}%';
    final title = job.fileName.isNotEmpty
        ? job.fileName
        : job.jobName.replaceAll('\\', '/').split('/').last;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (entry.source.label != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(entry.source.label!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.primary)),
            ),
          Row(
            children: [
              Expanded(
                child: Tooltip(
                  message: title,
                  waitDuration: const Duration(milliseconds: 500),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              if (progressText != null)
                Text(
                  progressText,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              const SizedBox(width: 4),
              SizedBox(
                width: 24,
                height: 24,
                child: IconButton(
                  tooltip: translate('Cancel'),
                  padding: EdgeInsets.zero,
                  iconSize: 16,
                  onPressed: () => _dismiss(entry),
                  icon: Icon(
                    Icons.close,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.70),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 7,
              backgroundColor: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation<Color>(
                Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _remoteDropProgressStatus(job),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.72),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  double? _remoteDropProgressValue(JobProgress job) {
    if (job.totalSize <= 0) return null;
    return (job.finishedSize / job.totalSize).clamp(0.0, 1.0).toDouble();
  }

  String _remoteDropProgressStatus(JobProgress job) {
    if (job.state == JobState.error) {
      return job.err.isNotEmpty ? job.err : translate('Error');
    }
    if (job.state == JobState.paused) {
      return translate('Waiting');
    }

    final parts = <String>[];
    if (job.totalSize > 0) {
      final finishedSize =
          job.finishedSize > job.totalSize ? job.totalSize : job.finishedSize;
      parts.add(
        '${readableFileSize(finishedSize.toDouble())} / ${readableFileSize(job.totalSize.toDouble())}',
      );
    }
    if (job.speed > 0 && job.state == JobState.inProgress) {
      parts.add('${readableFileSize(job.speed)}/s');
    }
    if (job.fileCount > 1) {
      var handledFileCount = job.recvJobRes ? job.fileNum + 1 : job.fileNum;
      if (handledFileCount > job.fileCount) handledFileCount = job.fileCount;
      parts.add('$handledFileCount/${job.fileCount} files');
    }
    return parts.isEmpty
        ? '\ubcf5\uc0ac \uc900\ube44 \uc911'
        : parts.join('  ');
  }

  void _dismiss(_TransferJob entry) {
    final job = entry.job;
    final jobController = entry.source.controller;
    if (job.state == JobState.none ||
        job.state == JobState.inProgress ||
        job.state == JobState.paused) {
      unawaited(jobController.cancelJob(job.id));
    }
    final index = jobController.getJob(job.id);
    if (index >= 0) {
      jobController.jobTable.removeAt(index);
      jobController.jobTable.refresh();
    }
  }
}
