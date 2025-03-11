# Keep all classes related to Razorpay SDK
-keep class com.razorpay.** { *; }
-keep class proguard.annotation.Keep { *; }
-keep class proguard.annotation.KeepClassMembers { *; }
-keep @proguard.annotation.Keep class *
-keep @proguard.annotation.KeepClassMembers class *
-keepattributes *Annotation*

# Keep Google Pay-related classes used by Razorpay
-keep class com.google.android.apps.nbu.paisa.inapp.client.api.** { *; }
-keep class com.google.android.gms.wallet.** { *; }
-keep class com.razorpay.RzpGpayMerged { *; }
-keep class com.razorpay.AnalyticsConstants { *; }

# Keep necessary AndroidX and Kotlin classes
-keep class androidx.** { *; }
-keep class kotlin.** { *; }
-keep class com.google.android.gms.** { *; }

# Prevent removing methods and fields from Razorpay analytics
-keepclassmembers class com.razorpay.** {
    @proguard.annotation.KeepClassMembers *;
}

# Additional Keep Rules
-dontwarn com.google.android.apps.nbu.paisa.inapp.client.api.**
-dontwarn proguard.annotation.Keep
-dontwarn proguard.annotation.KeepClassMembers
