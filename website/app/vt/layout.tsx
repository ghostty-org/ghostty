import Image from "next/image";
import Link from "next/link";
import "@/styles/code.css";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="max-w-[850px] justify-center ml-auto mr-auto">
      <div className="mt-4 mb-4">
        <Link href="/">
          <Image src="/icon-gs.png" width={50} height={50} alt="Ghostty Logo" />
        </Link>
      </div>

      <div className="font-mono">
        <div className="max-w-full prose prose-h1:text-base prose-h1:font-bold prose-h2:text-base prose-h2:font-bold prose-h3:text-base prose-h3:font-bold prose-p:text-base prose-h1:m-0 prose-h1:mb-1.5 prose-h2:m-0 prose-h2:mb-1.5 prose-h3:m-0 prose-h3:mb-1.5 prose-invert">
          {children}
        </div>
      </div>
    </div>
  );
}
