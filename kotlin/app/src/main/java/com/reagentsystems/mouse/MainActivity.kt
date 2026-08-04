package com.reagentsystems.mouse

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent

/**
 * Mouse for Android. The whole app is the gesture shell ([ForegroundView]) — same interaction
 * spec and design language as the Swift app; built natively in Compose.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        GitHub.attach(applicationContext)
        Runtimes.attach(applicationContext)
        val base = filesDir
        setContent { ForegroundView(base) }
    }
}
