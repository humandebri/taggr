package org.taggr.android.data

import android.accounts.Account
import android.app.*
import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.*
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.*
import androidx.annotation.RequiresApi
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.ic4j.agent.android.ICClient
import org.taggr.android.MainActivity

internal object YouTubeBackground {
    const val JOB_ID = 7412
    const val NOTIFICATION_ID = 7412
    const val CHANNEL = "youtube-upload"
    val dispatch = Mutex()

    private data class Owner(val principal: String?)

    @Volatile private var observedOwner: Owner? = null
    @Volatile private var activeOwner: String? = null
    @Volatile private var fallbackQueued: PersistableBundle? = null
    private val active = java.util.concurrent.ConcurrentHashMap<String, Job>()
    private val targets = java.util.concurrent.ConcurrentHashMap<String, PersistableBundle>()

    fun observeOwner(context: Context, principal: String?) {
        observedOwner = Owner(principal)
        if (
            (activeOwner != null && activeOwner != principal) ||
                (fallbackQueued != null && fallbackQueued?.getString("owner") != principal)
        )
            pause(context)
    }

    fun track(key: String, values: PersistableBundle, work: Job) {
        activeOwner = values.getString("owner")
        active[key] = work
        targets[key] = PersistableBundle(values)
        if (key == "fallback" && fallbackQueued?.getString("id") == values.getString("id"))
            fallbackQueued = null
    }

    fun untrack(key: String, work: Job) {
        if (active.remove(key, work)) targets.remove(key)
        if (active.isEmpty()) activeOwner = null
    }

    fun pause(context: Context) {
        val running = isRunning(context)
        fallbackQueued = null
        if (Build.VERSION.SDK_INT >= 34)
            context.getSystemService(JobScheduler::class.java).cancel(JOB_ID)
        context.stopService(Intent(context, YouTubeUploadFallbackService::class.java))
        active.values.forEach { it.cancel() }
        if (running) pausedNotification(context)
    }

    fun pausedNotification(context: Context) {
        if (
            Build.VERSION.SDK_INT < 33 ||
                context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                    android.content.pm.PackageManager.PERMISSION_GRANTED
        )
            context
                .getSystemService(NotificationManager::class.java)
                .notify(
                    NOTIFICATION_ID,
                    notification(
                        context,
                        "Upload paused. Reopen the original account and draft.",
                        running = false,
                    ),
                )
    }

    suspend fun pauseAndWait(context: Context) {
        val tasks = active.values.toList()
        pause(context)
        tasks.forEach { it.join() }
    }

    fun extras(job: YouTubeUploadJob, namespace: String = "main") =
        PersistableBundle().apply {
            require(job.googleAccountEmail != null)
            putString("id", job.id)
            putString("namespace", namespace)
            putString("owner", job.target.owner)
            putString("network", job.target.network)
            putString("canister", job.target.canister)
            putString("channel", job.target.channelId)
            putString("draft", job.target.draftSlot)
        }

    fun start(context: Context, job: YouTubeUploadJob, namespace: String = "main") {
        val values = extras(job, namespace)
        if (Build.VERSION.SDK_INT >= 34) {
            val info =
                JobInfo.Builder(JOB_ID, ComponentName(context, YouTubeUploadJobService::class.java))
                    .setUserInitiated(true)
                    .setRequiredNetwork(
                        NetworkRequest.Builder()
                            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                            .build()
                    )
                    .setEstimatedNetworkBytes(
                        20000,
                        (job.byteCount - job.acknowledgedBytes).coerceAtLeast(1),
                    )
                    .setExtras(values)
                    .build()
            check(
                context.getSystemService(JobScheduler::class.java).schedule(info) ==
                    JobScheduler.RESULT_SUCCESS
            ) {
                "The upload could not start. Resume it while TAGGR is open."
            }
        } else startFallback(context, values)
    }

    fun startFallback(context: Context, values: PersistableBundle) {
        val queued = PersistableBundle(values)
        fallbackQueued = queued
        try {
            check(
                context.startForegroundService(
                    Intent(context, YouTubeUploadFallbackService::class.java)
                        .putExtra("upload", values)
                ) != null
            ) {
                "The upload service could not start."
            }
        } catch (error: Throwable) {
            if (fallbackQueued === queued) fallbackQueued = null
            throw error
        }
    }

    fun notification(
        context: Context,
        status: String,
        job: YouTubeUploadJob? = null,
        running: Boolean = true,
    ): Notification {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Video uploads", NotificationManager.IMPORTANCE_LOW)
        )
        val open =
            PendingIntent.getActivity(
                context,
                7412,
                Intent(context, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val pause =
            PendingIntent.getBroadcast(
                context,
                7412,
                Intent(context, YouTubeUploadPauseReceiver::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        return Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("TAGGR YouTube upload")
            .setContentText(status)
            .setContentIntent(open)
            .setOngoing(running)
            .setOnlyAlertOnce(true)
            .apply {
                if (running) addAction(Notification.Action.Builder(null, "Pause", pause).build())
                if (job != null && running)
                    setProgress(100, (100.0 * job.acknowledgedBytes / job.byteCount).toInt(), false)
            }
            .build()
    }

    private suspend fun owner(context: Context, client: ICClient): String? {
        val observed = observedOwner
        if (observed != null && observed.principal == null) return null
        return withContext(Dispatchers.IO) {
            val session =
                client.loadSession(client.sessionStore(context, "taggr-account"))
                    ?: return@withContext null
            try {
                val principal = session.principal().toString()
                if (
                    sessionRemainingMillis(session.expiration(), System.currentTimeMillis()) > 0 &&
                        (observed == null || observed.principal == principal)
                )
                    principal
                else null
            } finally {
                session.close()
            }
        }
    }

    fun isRunning(context: Context): Boolean =
        fallbackQueued != null ||
            active.isNotEmpty() ||
            (Build.VERSION.SDK_INT >= 34 &&
                context.getSystemService(JobScheduler::class.java).getPendingJob(JOB_ID) != null)

    fun isRunningForDraft(
        context: Context,
        owner: String?,
        network: String,
        canister: String,
        slot: String,
    ): Boolean {
        if (owner == null) return false
        fun matches(values: PersistableBundle) =
            values.getString("owner") == owner &&
                values.getString("network") == network &&
                values.getString("canister") == canister &&
                values.getString("draft") == slot
        return fallbackQueued?.let { matches(it) } == true ||
            targets.any { (key, values) -> active.containsKey(key) && matches(values) } ||
            (Build.VERSION.SDK_INT >= 34 &&
                context
                    .getSystemService(JobScheduler::class.java)
                    .getPendingJob(JOB_ID)
                    ?.extras
                    ?.let { matches(it) } == true)
    }

    /** Refresh is account-bound. A background caller never launches foreground consent. */
    suspend fun execute(
        context: Context,
        values: PersistableBundle,
        wake: YouTubeUploadWake? = null,
        update: (String, YouTubeUploadJob?, Boolean) -> Unit,
    ) = dispatch.withLock {
        val target =
            YouTubeDraftTarget(
                requireNotNull(values.getString("owner")),
                requireNotNull(values.getString("network")),
                requireNotNull(values.getString("canister")),
                requireNotNull(values.getString("channel")),
                requireNotNull(values.getString("draft")),
            )
        val configuration = TaggrRuntime.configuration()
        require(
            target.network == financialNetwork(configuration) &&
                target.canister == configuration.canisterId
        )
        val store = YouTubeUploadJobStore(context, values.getString("namespace") ?: "main")
        var saved =
            requireNotNull(
                if (wake == null) store.load(target) else wake.run { store.load(target) }
            )
        require(saved.id == values.getString("id") && saved.googleAccountEmail != null)
        ICClient(configuration).use { client ->
            val auth = GoogleYouTubeAuth(context)
            val account = Account(requireNotNull(saved.googleAccountEmail), "com.google")
            suspend fun authorize(): YouTubeAuthorization {
                require(owner(context, client) == target.owner)
                return auth.authorize(account, target.channelId)
            }
            val access = if (wake == null) authorize() else wake.run { authorize() }
            if (access is YouTubeAuthorization.Resolution) {
                if (saved.phase !in listOf(YouTubeJobPhase.COMPLETED, YouTubeJobPhase.CANCELLED)) {
                    val required = saved.copy(phase = YouTubeJobPhase.AUTHORIZATION_REQUIRED)
                    store.save(required, saved)
                    saved = required
                }
                update("Reconnect YouTube in the original draft.", saved, false)
                return@withLock
            }
            access as YouTubeAuthorization.Access
            val runner =
                YouTubeUploadRunner(
                    YouTubeUploadTransport(),
                    { old, new -> store.save(new, old) },
                    store::source,
                )
            val result =
                YouTubeUploadExecution(
                        runner,
                        { owner(context, client) },
                        dispatch = {
                            if (wake == null) it() else wake.run(it)
                        },
                    )
                    .run(
                        saved,
                        target,
                        YouTubeUploadCredentials(
                            access.token,
                            access.account.name,
                            access.channel.id,
                        ),
                    ) { step ->
                        update("Uploading video", step.job, true)
                        if (step.job.phase == YouTubeJobPhase.AUTHORIZATION_REQUIRED)
                            auth.clearExpiredToken(access)
                    }
            update(
                if (result.phase == YouTubeJobPhase.COMPLETED)
                    "Upload complete. Open the original draft to use the video."
                else "Upload paused. Open the original draft to continue.",
                result,
                false,
            )
        }
    }
}

class YouTubeUploadPauseReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        YouTubeBackground.pause(context)
    }
}

@RequiresApi(34)
class YouTubeUploadJobService : android.app.job.JobService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val work = java.util.IdentityHashMap<android.app.job.JobParameters, Job>()

    override fun onStartJob(params: android.app.job.JobParameters): Boolean {
        setNotification(
            params,
            YouTubeBackground.NOTIFICATION_ID,
            YouTubeBackground.notification(this, "Preparing video upload"),
            JOB_END_NOTIFICATION_POLICY_DETACH,
        )
        val key = "job-${params.jobId}"
        val task =
            scope.launch(start = CoroutineStart.LAZY) {
                try {
                    YouTubeBackground.execute(this@YouTubeUploadJobService, params.extras) {
                        text,
                        job,
                        running ->
                        setNotification(
                            params,
                            YouTubeBackground.NOTIFICATION_ID,
                            YouTubeBackground.notification(
                                this@YouTubeUploadJobService,
                                text,
                                job,
                                running,
                            ),
                            JOB_END_NOTIFICATION_POLICY_DETACH,
                        )
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (_: org.ic4j.agent.AgentError) {
                    YouTubeBackground.pausedNotification(this@YouTubeUploadJobService)
                } catch (_: Exception) {
                    setNotification(
                        params,
                        YouTubeBackground.NOTIFICATION_ID,
                        YouTubeBackground.notification(
                            this@YouTubeUploadJobService,
                            "Upload paused. Reopen the original account and draft.",
                            running = false,
                        ),
                        JOB_END_NOTIFICATION_POLICY_DETACH,
                    )
                } finally {
                    val own = coroutineContext[Job]!!
                    YouTubeBackground.untrack(key, own)
                    if (work.remove(params) === own) jobFinished(params, false)
                }
            }
        work[params] = task
        YouTubeBackground.track(key, params.extras, task)
        task.start()
        return true
    }

    override fun onStopJob(params: android.app.job.JobParameters): Boolean {
        work.remove(params)?.cancel()
        YouTubeBackground.pausedNotification(this)
        return params.stopReason != android.app.job.JobParameters.STOP_REASON_CANCELLED_BY_APP
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}

class YouTubeUploadFallbackService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var work: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(
            YouTubeBackground.NOTIFICATION_ID,
            YouTubeBackground.notification(this, "Preparing video upload"),
        )
        val values = intent?.getParcelableExtra<PersistableBundle>("upload")
        if (values == null) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val previous = work
        val task =
            scope.launch(start = CoroutineStart.LAZY) {
                try {
                    previous?.cancelAndJoin()
                    withTimeout(30 * 60 * 1000L) {
                        YouTubeBackground.execute(
                            this@YouTubeUploadFallbackService,
                            values,
                            YouTubeUploadWake(this@YouTubeUploadFallbackService),
                        ) { text, job, running ->
                            getSystemService(NotificationManager::class.java)
                                .notify(
                                    YouTubeBackground.NOTIFICATION_ID,
                                    YouTubeBackground.notification(
                                        this@YouTubeUploadFallbackService,
                                        text,
                                        job,
                                        running,
                                    ),
                                )
                        }
                    }
                } catch (_: TimeoutCancellationException) {
                    YouTubeBackground.pausedNotification(this@YouTubeUploadFallbackService)
                } catch (e: CancellationException) {
                    throw e
                } catch (_: org.ic4j.agent.AgentError) {
                    YouTubeBackground.pausedNotification(this@YouTubeUploadFallbackService)
                } catch (_: Exception) {
                    getSystemService(NotificationManager::class.java)
                        .notify(
                            YouTubeBackground.NOTIFICATION_ID,
                            YouTubeBackground.notification(
                                this@YouTubeUploadFallbackService,
                                "Upload paused. Reopen the original account and draft.",
                                running = false,
                            ),
                        )
                } finally {
                    YouTubeBackground.untrack("fallback", coroutineContext[Job]!!)
                    if (work === coroutineContext[Job]) {
                        stopForeground(STOP_FOREGROUND_DETACH)
                        stopSelf(startId)
                    }
                }
            }
        work = task
        YouTubeBackground.track("fallback", values, task)
        task.start()
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        YouTubeBackground.pausedNotification(this)
        work?.cancel()
        stopSelf()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
