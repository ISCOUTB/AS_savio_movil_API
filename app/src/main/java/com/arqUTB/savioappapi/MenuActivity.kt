package com.arqUTB.savioappapi

import android.content.Intent
import android.os.Bundle
import android.webkit.CookieManager
import android.webkit.WebStorage
import android.webkit.WebViewDatabase
import android.widget.Button
import android.widget.ImageButton
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.card.MaterialCardView
import com.google.android.material.bottomsheet.BottomSheetDialog

class MenuActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_menu)
        supportActionBar?.hide()

        val btnProfile = findViewById<ImageButton>(R.id.btnProfile)
        val cardMoodle = findViewById<MaterialCardView>(R.id.cardMoodle)
        val cardCalendar = findViewById<MaterialCardView>(R.id.cardCalendar)
        val cardNotes = findViewById<MaterialCardView>(R.id.cardNotes)

        cardMoodle.setOnClickListener { Toast.makeText(this, "Abrir SAVIO/Moodle (pendiente)", Toast.LENGTH_SHORT).show() }
        cardCalendar.setOnClickListener { Toast.makeText(this, "Abrir Calendario inteligente (pendiente)", Toast.LENGTH_SHORT).show() }
        cardNotes.setOnClickListener { Toast.makeText(this, "Abrir Gestor de apuntes rápidos (pendiente)", Toast.LENGTH_SHORT).show() }

        btnProfile.setOnClickListener { mostrarPerfil() }
    }

    private fun mostrarPerfil() {
        val dialog = BottomSheetDialog(this)
        val view = layoutInflater.inflate(R.layout.bottom_sheet_profile, null)
        dialog.setContentView(view)
        val lblSesion = view.findViewById<TextView>(R.id.lblSesion)
        val btnCerrar = view.findViewById<Button>(R.id.btnCerrarSesion)

        lblSesion.text = "Sesión Microsoft activa"

        btnCerrar.setOnClickListener {
            btnCerrar.isEnabled = false
            btnCerrar.text = "Cerrando..."
            AuthManager.signOut {
                limpiarRestosWebView()
                UserSession.clear()
                runOnUiThread {
                    val i = Intent(this, MainActivity::class.java)
                    i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                    startActivity(i)
                    finish()
                }
            }
        }

        dialog.show()
    }

    private fun limpiarRestosWebView() {
        // Por si quedaron cookies antiguas del flujo previo
        try {
            val cm = CookieManager.getInstance()
            cm.removeAllCookies(null)
            cm.removeSessionCookies(null)
            cm.flush()
            WebStorage.getInstance().deleteAllData()
            WebViewDatabase.getInstance(this).clearFormData()
        } catch (_: Exception) { }
    }
}
