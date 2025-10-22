package com.example.jupotify;

import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.app.PendingIntent;
import android.widget.RemoteViews;
import android.content.SharedPreferences;
import android.net.Uri;
import android.util.Log;
import es.antonborri.home_widget.HomeWidgetBackgroundReceiver;

public class HomeWidgetProvider extends AppWidgetProvider {
    @Override
    public void onUpdate(Context context, AppWidgetManager appWidgetManager, int[] appWidgetIds) {
        updateAll(context);
    }

    public static void updateAll(Context context) {
        AppWidgetManager appWidgetManager = AppWidgetManager.getInstance(context);
        int[] appWidgetIds = appWidgetManager.getAppWidgetIds(new ComponentName(context, HomeWidgetProvider.class));
        for (int appWidgetId : appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId);
        }
    }

    private static void updateAppWidget(Context context, AppWidgetManager appWidgetManager, int appWidgetId) {
        RemoteViews views = new RemoteViews(context.getPackageName(), R.layout.home_widget);

        // Read values saved from Flutter via HomeWidget.saveWidgetData
        SharedPreferences prefs = context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE);
        String title = prefs.getString("title", null);
        // progress removed from widget UI
        int isPlaying = prefs.getInt("isPlaying", 0);

        if (title == null || title.isEmpty()) {
            views.setTextViewText(R.id.title, "Nothing Playing");
            views.setImageViewResource(R.id.art, R.mipmap.launcher_icon);
        } else {
            views.setTextViewText(R.id.title, title);
            // For now we show app icon as placeholder artwork
            views.setImageViewResource(R.id.art, R.mipmap.launcher_icon);
        }

        // Play button icon based on state
        if (isPlaying == 1) {
            views.setImageViewResource(R.id.play, android.R.drawable.ic_media_pause);
        } else {
            views.setImageViewResource(R.id.play, android.R.drawable.ic_media_play);
        }

        // Artwork
        String art = prefs.getString("art", "");
        if (art != null && !art.isEmpty()) {
            try {
                Uri artUri = Uri.parse(art);
                String scheme = artUri.getScheme();
                if ("file".equalsIgnoreCase(scheme) || "content".equalsIgnoreCase(scheme)) {
                    views.setImageViewUri(R.id.art, artUri);
                } else {
                    views.setImageViewResource(R.id.art, R.mipmap.launcher_icon);
                }
            } catch (Exception e) {
                views.setImageViewResource(R.id.art, R.mipmap.launcher_icon);
            }
        } else {
            views.setImageViewResource(R.id.art, R.mipmap.launcher_icon);
        }

        // Button intents: launch app with deep-link so Flutter can handle
        Intent prevIntent = new Intent(context, HomeWidgetBackgroundReceiver.class);
        prevIntent.setAction("es.antonborri.home_widget.BACKGROUND");
        prevIntent.putExtra("homeWidgetBackgroundUri", "homewidget://ACTION_PREV");
        PendingIntent prevPI = PendingIntent.getBroadcast(context, 100, prevIntent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        views.setOnClickPendingIntent(R.id.prev, prevPI);

        Intent playIntent = new Intent(context, HomeWidgetBackgroundReceiver.class);
        playIntent.setAction("es.antonborri.home_widget.BACKGROUND");
        playIntent.putExtra("homeWidgetBackgroundUri", "homewidget://ACTION_TOGGLE");
        PendingIntent playPI = PendingIntent.getBroadcast(context, 101, playIntent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        views.setOnClickPendingIntent(R.id.play, playPI);

        Intent nextIntent = new Intent(context, HomeWidgetBackgroundReceiver.class);
        nextIntent.setAction("es.antonborri.home_widget.BACKGROUND");
        nextIntent.putExtra("homeWidgetBackgroundUri", "homewidget://ACTION_NEXT");
        PendingIntent nextPI = PendingIntent.getBroadcast(context, 102, nextIntent, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        views.setOnClickPendingIntent(R.id.next, nextPI);

        appWidgetManager.updateAppWidget(appWidgetId, views);
    }

    @Override
    public void onReceive(Context context, Intent intent) {
        super.onReceive(context, intent);
        String action = intent.getAction();
        if (action == null) return;
        // Only handle our custom actions; ignore APPWIDGET_UPDATE etc. to avoid loops/flicker
        if (!action.equals("ACTION_PREV") && !action.equals("ACTION_TOGGLE") && !action.equals("ACTION_NEXT")) {
            return;
        }
        Log.d("AppWidgetProvider", "onReceive action=" + action);
        // Relay to Flutter via deep-link so widgetClicked stream fires (fallback)
        Intent launch = new Intent(context, MainActivity.class);
        launch.setAction(Intent.ACTION_VIEW);
        launch.setData(Uri.parse("homewidget://" + action));
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        try { context.startActivity(launch); } catch (Exception ignored) {}
    }
}


